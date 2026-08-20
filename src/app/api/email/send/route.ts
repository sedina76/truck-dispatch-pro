import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { type EmailAttachment } from "@/lib/email/provider";
import { sendTenantEmail } from "@/lib/email/send-pipeline";
import { resolveEmailAuthorizationContext } from "@/lib/email/authorization";
import type { EmailPurpose } from "@/lib/email/purposes";
import { resolveEmailForEntity } from "@/lib/email/resolve-entity";
import { renderInvoiceOnlyPdf } from "@/lib/invoices/pdf";
import { renderReceiptPdf } from "@/lib/payments/pdf";
import { renderCarrierSettlementPdf, renderDriverSettlementPdf } from "@/lib/settlements/pdf";

// This route never fakes a successful send: with no provider configured,
// or on any expected business failure, sendTenantEmail() (Phase 2F's
// central pipeline, src/lib/email/send-pipeline.ts) returns a typed
// {ok:false} result and writes the truthful email_send_log ledger row
// itself -- this route's own job is only re-resolving the authoritative
// recipient/attachment/blocked state (never trusting whatever the client
// last saw from /api/email/resolve). Auth/org/cross-org re-verification
// now happens via resolveEmailAuthorizationContext() +
// sendTenantEmail()'s own internal entity-ownership check (spec review
// item 2) -- organizationId is never a raw string this route hands the
// pipeline. No direct Resend call and no manual ledger insert remain in
// this file after Phase 2F (spec sections 16/31).

const ENTITY_TABLES: Record<string, string> = {
  invoice: "invoices",
  statement: "statements",
  carrier_settlement: "settlements",
  driver_settlement: "driver_settlements",
  payment: "payments",
};

const ENTITY_TYPE_TO_PURPOSE: Record<string, EmailPurpose> = {
  invoice: "invoice",
  statement: "statement",
  carrier_settlement: "settlement",
  driver_settlement: "settlement",
  payment: "receipt",
};

async function fetchAttachment(
  supabase: Awaited<ReturnType<typeof createClient>>,
  attachmentType: string,
  entityId: string,
  numberLabel: string,
  packetStoragePath: string | undefined,
  statementStoragePath: string | undefined
): Promise<EmailAttachment> {
  const safeName = numberLabel.replace(/[^A-Za-z0-9._-]/g, "_");

  switch (attachmentType) {
    case "invoice_pdf":
      return { filename: `${safeName}.pdf`, content: await renderInvoiceOnlyPdf(entityId) };
    case "billing_packet_pdf": {
      if (!packetStoragePath) throw new Error("Billing packet file is missing.");
      const { data, error } = await supabase.storage.from("billing-packets").download(packetStoragePath);
      if (error || !data) throw new Error("Could not read the stored billing packet.");
      return { filename: `${safeName}-billing-packet.pdf`, content: Buffer.from(await data.arrayBuffer()) };
    }
    case "statement_pdf": {
      if (!statementStoragePath) throw new Error("Statement file is missing.");
      const { data, error } = await supabase.storage.from("statements").download(statementStoragePath);
      if (error || !data) throw new Error("Could not read the stored statement.");
      return { filename: `${safeName}.pdf`, content: Buffer.from(await data.arrayBuffer()) };
    }
    case "carrier_settlement_pdf":
      return { filename: `${safeName}.pdf`, content: await renderCarrierSettlementPdf(entityId) };
    case "driver_settlement_pdf":
      return { filename: `${safeName}.pdf`, content: await renderDriverSettlementPdf(entityId) };
    case "receipt_pdf":
      return { filename: `${safeName}.pdf`, content: await renderReceiptPdf(entityId) };
    default:
      throw new Error("Unknown attachment type.");
  }
}

export async function POST(req: Request) {
  const body = await req.json();
  const { entityType, entityId, to, cc, subject, message } = body as {
    entityType: string;
    entityId: string;
    to: string;
    cc?: string;
    subject: string;
    message: string;
  };

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "Not authenticated." }, { status: 401 });
  const userId = user.id;

  const auth = await resolveEmailAuthorizationContext();
  if (!auth.ok) return NextResponse.json({ error: auth.error }, { status: 403 });
  const organizationId = auth.context.organizationId;

  if (!to) {
    return NextResponse.json({ error: "No recipient email is on file for this record." }, { status: 400 });
  }

  // Re-verify entityId actually belongs to the caller's org under RLS.
  // Cross-org entityId simply doesn't exist under this session's RLS, so
  // this (and every query resolveEmailForEntity makes below) returns
  // "not found" rather than another org's data -- a valid Resend API key
  // never becomes a cross-org bypass.
  const table = ENTITY_TABLES[entityType];
  if (!table) return NextResponse.json({ error: "Unknown entity type." }, { status: 400 });
  const { data: entity } = await supabase.from(table).select("id").eq("id", entityId).maybeSingle();
  if (!entity) return NextResponse.json({ error: "Record not found." }, { status: 404 });

  // Re-resolve the authoritative attachment/blocked state server-side --
  // never trust a client-supplied attachmentType or a stale "not blocked"
  // from whenever the dialog was opened. Also covers the "no provider
  // configured" case honestly below via sendTenantEmail() itself, rather
  // than a separate early check duplicating that logic.
  const resolved = await resolveEmailForEntity(entityType, entityId, supabase);
  if ("error" in resolved) return NextResponse.json({ error: resolved.error }, { status: resolved.status });

  // Two pre-send business-rule blocks stay local to this route (they're
  // about THIS entity's own state -- void invoice, missing packet file --
  // not about sender/provider concerns the central pipeline owns). Both
  // still write an honest ledger row, matching this route's pre-Phase-2F
  // behavior exactly.
  async function logLocalBlock(status: "blocked" | "failed", error: string, attachmentType: string | null) {
    await supabase.from("email_send_log").insert({
      organization_id: organizationId,
      entity_type: entityType,
      entity_id: entityId,
      recipient: to,
      cc: cc || null,
      subject,
      attachment_type: attachmentType,
      status,
      error,
      sent_by: userId,
      email_purpose: ENTITY_TYPE_TO_PURPOSE[entityType] ?? null,
      to_addresses: to.split(",").map((a) => a.trim()).filter(Boolean),
    });
  }

  if (resolved.blocked) {
    await logLocalBlock("blocked", resolved.blocked, resolved.attachmentType);
    return NextResponse.json({ error: resolved.blocked }, { status: 409 });
  }

  let attachment: EmailAttachment;
  try {
    attachment = await fetchAttachment(supabase, resolved.attachmentType, entityId, resolved.numberLabel, resolved.packetStoragePath, resolved.statementStoragePath);
  } catch (err) {
    const error = err instanceof Error ? err.message : "Could not prepare the attachment.";
    await logLocalBlock("failed", error, resolved.attachmentType);
    return NextResponse.json({ error: "Email could not be sent. Please try again." }, { status: 502 });
  }

  // From here on, the central pipeline owns sender resolution, entity-
  // ownership re-verification, provider configuration checks, recipient
  // validation, the actual Resend call, and the email_send_log ledger row
  // -- no direct Resend call and no manual ledger insert remain in this
  // route (spec sections 16/31).
  const purpose = ENTITY_TYPE_TO_PURPOSE[entityType] ?? "invoice";
  const entities = entityType === "invoice" ? await resolveInvoiceLinkage(supabase, entityId) : {};

  // The compose dialog's To/CC fields are free-text and may already
  // contain a comma-separated list (same as this route accepted before
  // Phase 2F, when `to`/`cc` were passed straight through as raw strings)
  // -- split before validating, never treat "a@x.com, b@y.com" as one
  // malformed address.
  const result = await sendTenantEmail({
    authContext: auth.context,
    emailPurpose: purpose,
    to: to.split(",").map((a) => a.trim()).filter(Boolean),
    cc: cc ? cc.split(",").map((a) => a.trim()).filter(Boolean) : undefined,
    subject,
    text: message,
    attachments: [attachment],
    entityType,
    entityId,
    entities,
    sentBy: userId,
  });

  if (!result.ok) {
    return NextResponse.json({ error: result.error }, { status: result.duplicate ? 409 : 502 });
  }

  return NextResponse.json({ ok: true });
}

async function resolveInvoiceLinkage(supabase: Awaited<ReturnType<typeof createClient>>, invoiceId: string) {
  const { data: invoice } = await supabase.from("invoices").select("load_id, customer_id, broker_id").eq("id", invoiceId).maybeSingle();
  return { invoiceId, loadId: invoice?.load_id ?? null, customerId: invoice?.customer_id ?? null, brokerId: invoice?.broker_id ?? null };
}
