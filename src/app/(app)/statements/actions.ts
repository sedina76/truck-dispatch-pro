"use server";

import { randomUUID } from "node:crypto";
import { requireOperationalAccess } from "@/lib/billing/operational-access";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { computeStatementData, renderStatementPdf, type StatementKind, type StatementPartyType } from "@/lib/statements/generate";
import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

const UNIQUE_VIOLATION = "23505";

// Reserve-row-then-upload-then-rollback-on-failure, the exact hardened
// pattern proved out for billing packets (0025_billing_packet_race_
// hardening.sql / billing-packet-actions.ts): the row (and its id, which
// the storage path is keyed on) is created FIRST, so the PDF upload
// afterward can never collide with a concurrent generation -- each
// attempt gets its own immutable path regardless of how many statements
// are being generated at once. No SELECT-then-INSERT race exists here to
// begin with (statements are pure history, not versioned per (party,type)
// like billing packets are per invoice), but the same defensive rollback
// is applied anyway so a failed PDF build/upload never leaves an orphan
// "generated" row with no file behind it.
export async function generateStatement(formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const partyType = String(formData.get("party_type")) as StatementPartyType;
  const partyId = String(formData.get("party_id") || "");
  const statementType = String(formData.get("statement_type")) as StatementKind;
  const periodStart = (formData.get("period_start") as string) || null;
  const periodEnd = (formData.get("period_end") as string) || null;
  const asOfDate = (formData.get("as_of_date") as string) || new Date().toISOString().slice(0, 10);

  if (!partyId) throw new Error("Select a broker or customer first.");
  if (statementType === "period" && (!periodStart || !periodEnd)) {
    throw new Error("Select a start and end date for a period statement.");
  }

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const data = await computeStatementData({ partyType, partyId, statementType, periodStart, periodEnd, asOfDate });

  const statementId = randomUUID();
  const insertPayload = {
    id: statementId,
    organization_id: organizationId,
    party_type: partyType,
    broker_id: partyType === "broker" ? partyId : null,
    customer_id: partyType === "customer" ? partyId : null,
    statement_type: statementType,
    period_start: periodStart,
    period_end: periodEnd,
    as_of_date: asOfDate,
    opening_balance: data.openingBalance,
    closing_balance: data.closingBalance,
    status: "generated" as const,
    snapshot: {
      included_invoice_ids: data.includedInvoiceIds,
      included_payment_references: data.includedPaymentReferences,
      period_charges: data.periodCharges,
      period_payments: data.periodPayments,
      aging: data.aging,
    },
    generated_by: user?.id ?? null,
  };

  const { data: inserted, error: insertError } = await supabase.from("statements").insert(insertPayload).select("id, statement_number").single();
  if (insertError) {
    if (insertError.code === UNIQUE_VIOLATION) throw new Error("A statement with that number already exists -- try again.");
    throw new Error(insertError.message);
  }

  const storagePath = `${organizationId}/${partyType}/${partyId}/${statementId}/statement-${inserted.statement_number}.pdf`;

  try {
    const bytes = await renderStatementPdf(data, inserted.statement_number);
    const { error: uploadError } = await supabase.storage.from("statements").upload(storagePath, bytes, { contentType: "application/pdf", upsert: false });
    if (uploadError) throw new Error(uploadError.message);

    const { error: updateError } = await supabase.from("statements").update({ storage_path: storagePath }).eq("id", statementId);
    if (updateError) throw new Error(updateError.message);
  } catch (err) {
    // Rollback: never leave a "generated" row with no file behind it.
    await supabase.storage.from("statements").remove([storagePath]);
    await supabase.from("statements").delete().eq("id", statementId);
    throw err instanceof Error ? err : new Error("Statement generation failed.");
  }

  await supabase.rpc("log_activity", { p_entity_type: partyType === "broker" ? "broker" : "customer", p_entity_id: partyId, p_action: "statement_generated" });
  revalidatePath("/statements");
  redirect(`/statements/${statementId}`);
}

// Phase 2G.9 (item 10): same gap class as getPodSignedUrl/
// getBillingPacketSignedUrl -- a statement is a customer/broker AR
// document (open balance, aging, transaction history); this had no role
// check.
export async function getStatementSignedUrl(storagePath: string, download: boolean): Promise<string> {
  await requireRole(FINANCIAL_ROLES);
  const supabase = await createClient();
  const { data, error } = await supabase.storage.from("statements").createSignedUrl(storagePath, 300, download ? { download: true } : undefined);
  if (error || !data) throw new Error(error?.message ?? "Could not generate a document link.");
  return data.signedUrl;
}

// ---------------------------------------------------------------------------
// No email provider exists anywhere in this project (same finding as
// billing-packet-actions.ts and the Collections reminder module) -- this
// always fails clearly rather than pretending to send, and never writes
// sent_at/sent_by/status='sent' on failure.
// ---------------------------------------------------------------------------
export async function sendStatement(statementId: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const { data: statement } = await supabase.from("statements").select("id, recipient_email").eq("id", statementId).single();
  if (!statement) throw new Error("Statement not found.");

  const recipientEmail = String(formData.get("recipient_email") || "").trim();
  if (!recipientEmail) throw new Error("No recipient email on file.");

  throw new Error(
    "Email sending is not configured -- no email provider (e.g. Resend, SendGrid) is connected for this organization. Download the statement and send it manually for now."
  );
}
