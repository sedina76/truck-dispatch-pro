"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { generateBillingPacket as buildPacket, checkPacketReadiness } from "@/lib/billing-packet/generate";
import { getLatestDocument } from "@/lib/documents/latest-document";
import { sendTransactionalEmail, FRIENDLY_SEND_ERROR } from "@/lib/email/provider";
import { resolveOrgName } from "@/lib/email/resolve-entity";

const SUPPORTING_DOC_TYPES = ["rate_confirmation", "bol", "lumper_receipt", "detention_document", "scale_ticket", "other"];

// Postgres unique_violation.
const UNIQUE_VIOLATION = "23505";

export async function generatePacket(invoiceId: string) {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // Building the PDF is pure computation -- it only reads the invoice/load/
  // documents, never touches Storage or billing_packets -- so doing it
  // before reserving a row/version costs nothing and keeps the reservation
  // window (the only place concurrent requests can conflict) as short as
  // possible.
  const { bytes, documentSnapshot } = await buildPacket(invoiceId);

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
      return;
    }
    throw new Error(insertError.message);
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
    throw err instanceof Error ? err : new Error("Failed to upload billing packet.");
  }

  await supabase.rpc("log_activity", { p_entity_type: "invoice", p_entity_id: invoiceId, p_action: "billing_packet_generated" });
  revalidatePath(`/invoices/${invoiceId}`);
}

export async function getBillingPacketSignedUrl(storagePath: string, download: boolean): Promise<string> {
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

export async function sendBillingPacket(invoiceId: string, packetId: string, formData: FormData) {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const [{ data: invoice }, { data: packet }] = await Promise.all([
    supabase.from("invoices").select("*").eq("id", invoiceId).single(),
    supabase.from("billing_packets").select("*").eq("id", packetId).single(),
  ]);
  if (!invoice) throw new Error("Invoice not found.");
  if (!packet) throw new Error("Billing packet not found.");
  if (invoice.status === "void") throw new Error("Cannot send a voided invoice.");

  const readiness = await checkPacketReadiness(supabase, invoice.load_id);
  if (!readiness.ready) throw new Error(`Billing packet not ready. Missing: ${readiness.missing.join(", ")}`);

  const outdated = await isPacketOutdated(invoice.load_id, packet.document_snapshot);
  if (outdated) throw new Error("This billing packet is outdated -- regenerate it before sending.");

  const recipientEmail = String(formData.get("recipient_email") || invoice.bill_to_email || "").trim();
  if (!recipientEmail) throw new Error("No recipient email on file. Add a billing contact email before sending.");
  // Never send to the driver -- recipientEmail only ever comes from the
  // invoice's own bill_to_email (broker/customer billing contact) or an
  // explicit override typed into the send form, never a driver record.

  const subject = `Invoice ${invoice.invoice_number}`;
  const message = `Hello,\n\nPlease find attached the billing documents.\n\nInvoice: ${invoice.invoice_number}\nAmount Due: $${Number(invoice.total_amount).toLocaleString()}\n\nThank you,\n${await resolveOrgName(supabase)}`;

  async function logAttempt(status: "sent" | "failed", error: string | null, attachmentOk: boolean, providerMessageId: string | null) {
    await supabase.from("email_send_log").insert({
      organization_id: organizationId,
      entity_type: "invoice",
      entity_id: invoiceId,
      recipient: recipientEmail,
      subject,
      attachment_type: attachmentOk ? "billing_packet_pdf" : null,
      status,
      error,
      sent_at: status === "sent" ? new Date().toISOString() : null,
      provider_message_id: providerMessageId,
      sent_by: user?.id ?? null,
    });
  }

  const { data: fileData, error: downloadError } = await supabase.storage.from("billing-packets").download(packet.storage_path);
  if (downloadError || !fileData) {
    await logAttempt("failed", "Could not read the stored billing packet.", false, null);
    throw new Error(FRIENDLY_SEND_ERROR);
  }

  const sendResult = await sendTransactionalEmail({
    to: recipientEmail,
    subject,
    text: message,
    organizationName: await resolveOrgName(supabase),
    heading: subject,
    attachments: [{ filename: `${invoice.invoice_number}.pdf`, content: Buffer.from(await fileData.arrayBuffer()) }],
  });

  if (!sendResult.ok) {
    // Explicit failure, not a silent no-op: the invoice status is never
    // touched and the packet is never marked sent unless this actually
    // succeeds.
    await logAttempt("failed", sendResult.error, true, null);
    throw new Error(FRIENDLY_SEND_ERROR);
  }

  await logAttempt("sent", null, true, sendResult.providerMessageId);

  const { error: updateError } = await supabase
    .from("billing_packets")
    .update({ status: "sent", sent_at: new Date().toISOString(), sent_by: user?.id ?? null, recipient_email: recipientEmail })
    .eq("id", packetId);
  if (updateError) throw new Error(updateError.message);

  // Reuses the existing invoice_requires_verified_pod_to_send trigger
  // (0023_pod_workflow.sql) rather than duplicating that check here --
  // this update goes through the exact same gate a manual status change
  // would, so the two can never drift apart.
  const { error: invoiceError } = await supabase.from("invoices").update({ status: "sent", sent_at: new Date().toISOString() }).eq("id", invoiceId);
  if (invoiceError) throw new Error(invoiceError.message);

  await supabase.rpc("log_activity", { p_entity_type: "invoice", p_entity_id: invoiceId, p_action: "billing_packet_sent" });
  revalidatePath(`/invoices/${invoiceId}`);
}
