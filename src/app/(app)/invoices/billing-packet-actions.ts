"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { generateBillingPacket as buildPacket, checkPacketReadiness } from "@/lib/billing-packet/generate";
import { getLatestDocument } from "@/lib/documents/latest-document";
import { resolveOrgName } from "@/lib/email/resolve-entity";
import { sendTenantEmail } from "@/lib/email/send-pipeline";
import { resolveEmailAuthorizationContext } from "@/lib/email/authorization";
import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

const SUPPORTING_DOC_TYPES = ["rate_confirmation", "bol", "lumper_receipt", "detention_document", "scale_ticket", "other"];

// Postgres unique_violation.
const UNIQUE_VIOLATION = "23505";

export type GeneratePacketResult = { ok: true; skippedDocuments: { label: string; filename: string; reason: string }[] } | { ok: false; error: string };

// Returns a typed result rather than throwing -- Next.js redacts a Server
// Action's thrown error message down to an opaque digest in production
// builds by default (confirmed live: the actual "Could not include the
// Proof of Delivery..." message reached the server log correctly but
// never the browser). Returning {ok:false, error} instead is this exact
// codebase's own established convention for actions that need to report a
// specific message back to the client (see src/app/(app)/dispatch/
// exceptions/actions.ts's acknowledgeException/assignException/etc.) --
// applied here for the same reason, not a new pattern. The caller
// (billing-packet-section.tsx's client-side button) reads this directly.
export async function generatePacket(invoiceId: string): Promise<GeneratePacketResult> {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // Building the PDF is pure computation -- it only reads the invoice/load/
  // documents, never touches Storage or billing_packets -- so doing it
  // before reserving a row/version costs nothing and keeps the reservation
  // window (the only place concurrent requests can conflict) as short as
  // possible. A malformed required POD (or any other business-rule
  // failure inside buildPacket) throws a clean Error there -- caught here
  // and converted to a typed result instead of propagating further.
  let bytes: Uint8Array;
  let documentSnapshot: Awaited<ReturnType<typeof buildPacket>>["documentSnapshot"];
  let skippedDocuments: Awaited<ReturnType<typeof buildPacket>>["skippedDocuments"];
  try {
    const result = await buildPacket(invoiceId);
    bytes = result.bytes;
    documentSnapshot = result.documentSnapshot;
    skippedDocuments = result.skippedDocuments; // optional supporting docs, non-fatal -- carried through to the success return below
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : "Could not generate the billing packet." };
  }

  const { data: existing } = await supabase
    .from("billing_packets")
    .select("version")
    .eq("invoice_id", invoiceId)
    .order("version", { ascending: false })
    .limit(1);
  const nextVersion = (existing?.[0]?.version ?? 0) + 1;

  // Reserve the DB row BEFORE any Storage write. The object path is keyed
  // on this row's own id (generated here, client-side, rather than left to
  // the table default) so it's known before insert and unique to this
  // specific generation attempt -- two concurrent requests can never
  // compute the same path, even when they guess the same nextVersion,
  // because each gets its own id. This is what actually eliminates the
  // Storage-level race: the only request that ever calls storage.upload()
  // is the one whose row insert won the unique(invoice_id, version) race.
  const packetId = randomUUID();
  const storagePath = `${organizationId}/${invoiceId}/${packetId}/billing-packet-v${nextVersion}.pdf`;

  const { error: insertError } = await supabase.from("billing_packets").insert({
    id: packetId,
    organization_id: organizationId,
    invoice_id: invoiceId,
    version: nextVersion,
    status: "generated",
    storage_path: storagePath,
    document_snapshot: documentSnapshot,
    generated_by: user?.id ?? null,
  });

  if (insertError) {
    if (insertError.code === UNIQUE_VIOLATION) {
      // Lost the race to a concurrent generation of the same version --
      // the only way two requests can land on the same nextVersion guess
      // is genuine concurrent generation, since rows are never deleted
      // except by this function's own upload-failure rollback below. This
      // request never called storage.upload(), so there is nothing to
      // clean up; just let the page revalidate and show whichever request
      // won.
      revalidatePath(`/invoices/${invoiceId}`);
      return { ok: true, skippedDocuments: [] };
    }
    return { ok: false, error: insertError.message };
  }

  // Row reserved -- this is now the only request that will ever attempt to
  // write to this exact path, since it's keyed on this row's own id.
  try {
    const { error: uploadError } = await supabase.storage
      .from("billing-packets")
      .upload(storagePath, bytes, { contentType: "application/pdf", upsert: false });
    if (uploadError) throw new Error(uploadError.message);
  } catch (err) {
    // Upload failed after the row was reserved. Roll back cleanly so a
    // failed generation never leaves a dangling version number or an
    // orphaned object behind: remove() is called defensively even though
    // the upload errored, in case bytes partially landed before the error
    // was raised; it's a harmless no-op against a path that was never
    // written.
    await supabase.storage.from("billing-packets").remove([storagePath]);
    await supabase.from("billing_packets").delete().eq("id", packetId);
    return { ok: false, error: err instanceof Error ? err.message : "Failed to upload billing packet." };
  }

  await supabase.rpc("log_activity", { p_entity_type: "invoice", p_entity_id: invoiceId, p_action: "billing_packet_generated" });
  revalidatePath(`/invoices/${invoiceId}`);
  return { ok: true, skippedDocuments };
}

// Phase 2G.9 (item 10) finding: this had no role check at all -- a billing
// packet is the full customer-facing invoice packet (rate, totals, POD,
// supporting documents), and any authenticated caller who knew or guessed
// a storage path could invoke this Server Action directly and get a
// signed URL to it, regardless of role. Same class of gap as
// getPodSignedUrl before getFinancialDocumentSignedUrl was added.
export async function getBillingPacketSignedUrl(storagePath: string, download: boolean): Promise<string> {
  await requireRole(FINANCIAL_ROLES);
  const supabase = await createClient();
  const { data, error } = await supabase.storage
    .from("billing-packets")
    .createSignedUrl(storagePath, 300, download ? { download: true } : undefined);
  if (error || !data) throw new Error(error?.message ?? "Could not generate a document link.");
  return data.signedUrl;
}

// A packet is outdated in either direction:
//  (a) REPLACED: a document actually included in it (per its frozen
//      document_snapshot) is no longer the CURRENT latest document of that
//      type for the load -- a newer upload superseded it since generation.
//  (b) ADDED: an optional document type that had nothing on file at
//      generation time (so isn't in the snapshot at all) now has a document
//      available -- the packet is missing content it could now include.
// Never determined by filename; always by comparing the exact document id
// snapshotted at generation time against what's current right now.
export async function isPacketOutdated(
  loadId: string | null,
  documentSnapshot: { document_id: string; document_type: string; created_at: string }[]
): Promise<boolean> {
  if (!loadId) return false;
  const supabase = await createClient();

  const snapshotByType = new Map(documentSnapshot.map((s) => [s.document_type, s]));

  // (a) Replacement check, for every type that WAS included.
  for (const snap of documentSnapshot) {
    const current = await getLatestDocument(supabase, "load", loadId, snap.document_type);
    if (!current || current.id !== snap.document_id) return true;
  }

  // (b) Addition check, for every type that WASN'T included (POD is always
  // in the snapshot by the time a packet can even be generated, so this
  // only really applies to the optional supporting types).
  for (const type of ["pod", ...SUPPORTING_DOC_TYPES]) {
    if (snapshotByType.has(type)) continue;
    const current = await getLatestDocument(supabase, "load", loadId, type);
    if (current) return true;
  }

  return false;
}

export type SendBillingPacketResult = { ok: true } | { ok: false; error: string; uncertain?: boolean };

// Returns a typed result rather than throwing (same reasoning as
// generatePacket()/uploadLoadDocument() elsewhere in this app): a plain
// <form action={...}> replaces the whole page with Next's generic
// "Application error" boundary the instant a Server Action throws. The
// caller (SendBillingPacketForm, a client component) reads this return
// value and renders it inline instead. No business validation is
// loosened -- only how a failure is reported changed.
export async function sendBillingPacket(invoiceId: string, packetId: string, formData: FormData): Promise<SendBillingPacketResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // Spec review item 2: the pipeline itself re-derives/re-verifies
  // organization + entity ownership -- this is the ONLY way organizationId
  // reaches sendTenantEmail() below, never a raw string.
  const auth = await resolveEmailAuthorizationContext();
  if (!auth.ok) return { ok: false, error: auth.error };

  const [{ data: invoice }, { data: packet }] = await Promise.all([
    supabase.from("invoices").select("*").eq("id", invoiceId).single(),
    supabase.from("billing_packets").select("*").eq("id", packetId).single(),
  ]);
  if (!invoice) return { ok: false, error: "Invoice not found." };
  if (!packet) return { ok: false, error: "Billing packet not found." };
  if (invoice.status === "void") return { ok: false, error: "Cannot send a voided invoice." };

  const readiness = await checkPacketReadiness(supabase, invoice.load_id);
  if (!readiness.ready) return { ok: false, error: `Billing packet not ready. Missing: ${readiness.missing.join(", ")}` };

  const outdated = await isPacketOutdated(invoice.load_id, packet.document_snapshot);
  if (outdated) return { ok: false, error: "This billing packet is outdated -- regenerate it before sending." };

  const recipientEmail = String(formData.get("recipient_email") || invoice.bill_to_email || "").trim();
  if (!recipientEmail) return { ok: false, error: "No recipient email on file. Add a billing contact email before sending." };
  // Never send to the driver -- recipientEmail only ever comes from the
  // invoice's own bill_to_email (broker/customer billing contact) or an
  // explicit override typed into the send form, never a driver record.

  const subject = `Invoice ${invoice.invoice_number}`;
  const message = `Hello,\n\nPlease find attached the billing documents.\n\nInvoice: ${invoice.invoice_number}\nAmount Due: $${Number(invoice.total_amount).toLocaleString()}\n\nThank you,\n${await resolveOrgName(supabase)}`;

  const { data: fileData, error: downloadError } = await supabase.storage.from("billing-packets").download(packet.storage_path);
  if (downloadError || !fileData) return { ok: false, error: "Could not read the stored billing packet. Please try again." };

  // An explicit "Send Again" click (spec review item 1 -- required after
  // an 'uncertain' delivery outcome, distinct from an ordinary Send) is
  // signaled by the form itself, not inferred -- SendBillingPacketForm
  // sets this once it has actually shown the user an uncertain/duplicate
  // result and they've chosen to proceed anyway. Also true whenever the
  // packet has already been successfully sent, since clicking "Send
  // Billing Packet" again on an already-sent packet is inherently a
  // resend of the same version (spec section 34).
  const isExplicitResend = packet.status === "sent" || formData.get("force_resend") === "1";

  // Central pipeline (spec section 30): sender resolution, ledger row,
  // idempotency, provider call -- nothing here calls Resend or writes
  // email_send_log directly. Idempotency base key is versioned by the
  // packet's OWN version number (spec section 34): sending v1 twice by
  // accident (e.g. a double-click) is blocked at sequence 0; regenerating
  // and sending v2 is always a genuine, intentional new send under a
  // fresh base key, never blocked by the earlier one. An explicit resend
  // (see isExplicitResend above) always allocates a brand-new sequence,
  // so it can never collide with -- or be blocked by -- ANY prior attempt
  // at this key, including a stuck 'uncertain' one (spec review item 1).
  const sendResult = await sendTenantEmail({
    authContext: auth.context,
    emailPurpose: "billing_packet",
    to: [recipientEmail],
    subject,
    text: message,
    attachments: [{ filename: `${invoice.invoice_number}.pdf`, content: Buffer.from(await fileData.arrayBuffer()) }],
    entityType: "invoice",
    entityId: invoiceId,
    entities: { invoiceId, loadId: invoice.load_id, customerId: invoice.customer_id, brokerId: invoice.broker_id },
    sentBy: user?.id ?? null,
    idempotencyBaseKey: `billing_packet_sent:${invoiceId}:v${packet.version}`,
    isExplicitResend,
  });

  if (!sendResult.ok) {
    // Explicit failure, not a silent no-op: the invoice status is never
    // touched and the packet is never marked sent unless this actually
    // succeeds.
    return { ok: false, error: sendResult.error, uncertain: sendResult.uncertain };
  }

  const { error: updateError } = await supabase
    .from("billing_packets")
    .update({ status: "sent", sent_at: new Date().toISOString(), sent_by: user?.id ?? null, recipient_email: recipientEmail })
    .eq("id", packetId);
  if (updateError) return { ok: false, error: updateError.message };

  // Reuses the existing invoice_requires_verified_pod_to_send trigger
  // (0023_pod_workflow.sql) rather than duplicating that check here --
  // this update goes through the exact same gate a manual status change
  // would, so the two can never drift apart.
  const { error: invoiceError } = await supabase.from("invoices").update({ status: "sent", sent_at: new Date().toISOString() }).eq("id", invoiceId);
  if (invoiceError) return { ok: false, error: invoiceError.message };

  await supabase.rpc("log_activity", { p_entity_type: "invoice", p_entity_id: invoiceId, p_action: "billing_packet_sent" });
  revalidatePath(`/invoices/${invoiceId}`);
  return { ok: true };
}
