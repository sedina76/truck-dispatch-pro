import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { EMAIL_PROVIDER_CONFIGURED, sendTransactionalEmail, FRIENDLY_SEND_ERROR, type EmailAttachment } from "@/lib/email/provider";
import { resolveEmailForEntity } from "@/lib/email/resolve-entity";
import { renderInvoiceOnlyPdf } from "@/lib/invoices/pdf";
import { renderReceiptPdf } from "@/lib/payments/pdf";
import { renderCarrierSettlementPdf, renderDriverSettlementPdf } from "@/lib/settlements/pdf";

// This route never fakes a successful send: with no provider configured it
// always responds 501 and logs the attempt as `blocked`, never `sent`. Once
// configured, the actual send goes through the one shared
// sendTransactionalEmail() (src/lib/email/provider.ts) -- this route's job
// is only auth/org/cross-org re-verification, re-resolving the
// authoritative recipient/attachment/blocked state (never trusting
// whatever the client last saw from /api/email/resolve), and writing the
// truthful email_send_log row.

const ENTITY_TABLES: Record<string, string> = {
  invoice: "invoices",
  statement: "statements",
  carrier_settlement: "settlements",
  driver_settlement: "driver_settlements",
  payment: "payments",
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

  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return NextResponse.json({ error: "No organization on this account." }, { status: 403 });
  }

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

  if (!EMAIL_PROVIDER_CONFIGURED) {
    const error = "Email provider not configured.";
    // Log the attempt honestly -- status stays 'blocked', never 'sent', and
    // sent_at stays null (0053_email_send_log_resend.sql). RLS on
    // email_send_log enforces organization_id = the caller's own org
    // regardless of what a client sends, so this can't forge an audit row
    // for another org.
    await supabase.from("email_send_log").insert({
      organization_id: organizationId,
      entity_type: entityType,
      entity_id: entityId,
      recipient: to,
      cc: cc || null,
      subject,
      attachment_type: null,
      status: "blocked",
      error,
      sent_by: user.id,
    });
    return NextResponse.json({ error }, { status: 501 });
  }

  // Re-resolve the authoritative attachment/blocked state server-side --
  // never trust a client-supplied attachmentType or a stale "not blocked"
  // from whenever the dialog was opened.
  const resolved = await resolveEmailForEntity(entityType, entityId, supabase);
  if ("error" in resolved) return NextResponse.json({ error: resolved.error }, { status: resolved.status });

  if (resolved.blocked) {
    await supabase.from("email_send_log").insert({
      organization_id: organizationId,
      entity_type: entityType,
      entity_id: entityId,
      recipient: to,
      cc: cc || null,
      subject,
      attachment_type: resolved.attachmentType,
      status: "blocked",
      error: resolved.blocked,
      sent_by: user.id,
    });
    return NextResponse.json({ error: resolved.blocked }, { status: 409 });
  }

  let attachment: EmailAttachment;
  try {
    attachment = await fetchAttachment(supabase, resolved.attachmentType, entityId, resolved.numberLabel, resolved.packetStoragePath, resolved.statementStoragePath);
  } catch (err) {
    const error = err instanceof Error ? err.message : "Could not prepare the attachment.";
    await supabase.from("email_send_log").insert({
      organization_id: organizationId,
      entity_type: entityType,
      entity_id: entityId,
      recipient: to,
      cc: cc || null,
      subject,
      attachment_type: resolved.attachmentType,
      status: "failed",
      error,
      sent_by: user.id,
    });
    return NextResponse.json({ error: FRIENDLY_SEND_ERROR }, { status: 502 });
  }

  const result = await sendTransactionalEmail({
    to,
    cc,
    subject,
    text: message,
    organizationName: resolved.organizationName,
    heading: subject,
    attachments: [attachment],
  });

  if (!result.ok) {
    await supabase.from("email_send_log").insert({
      organization_id: organizationId,
      entity_type: entityType,
      entity_id: entityId,
      recipient: to,
      cc: cc || null,
      subject,
      attachment_type: resolved.attachmentType,
      status: "failed",
      error: result.error,
      sent_by: user.id,
    });
    return NextResponse.json({ error: FRIENDLY_SEND_ERROR }, { status: 502 });
  }

  await supabase.from("email_send_log").insert({
    organization_id: organizationId,
    entity_type: entityType,
    entity_id: entityId,
    recipient: to,
    cc: cc || null,
    subject,
    attachment_type: resolved.attachmentType,
    status: "sent",
    error: null,
    sent_at: new Date().toISOString(),
    provider_message_id: result.providerMessageId,
    sent_by: user.id,
  });

  return NextResponse.json({ ok: true });
}
