import { NextResponse } from "next/server";
import { Webhook, WebhookVerificationError } from "svix";
import { createServiceRoleClient } from "@/lib/supabase/service-role";

// The ONE central Resend webhook endpoint (spec sections 23-25). Resend
// signs every webhook using Svix (svix-id/svix-timestamp/svix-signature
// headers) -- this route uses the `svix` package (Resend's own
// documented/recommended verification mechanism) rather than a hand-rolled
// HMAC comparison, and NEVER processes a payload -- no database read, no
// database write, no provider call -- until signature verification has
// succeeded. Verification happens first, unconditionally, before anything
// else in this handler runs (spec review item 7).
//
// RESEND_WEBHOOK_SECRET is a server-only environment variable; it is never
// read by, or shipped to, any client code (spec section 24). Not to be
// confused with RESEND_API_KEY (the platform's outbound-send credential) --
// this is a separate secret Resend issues specifically for the webhook
// endpoint's signing key.
//
// Public route scope (spec review item 7): exactly `/api/webhooks/resend`
// is exempted from the Supabase session middleware (see PUBLIC_PATHS in
// src/lib/supabase/middleware.ts), not a broader `/api/webhooks` prefix --
// there is no general webhook-auth architecture in this app yet, so scope
// stays as narrow as what actually exists.

const EVENT_TYPE_TO_DELIVERY_STATUS: Record<string, string> = {
  "email.sent": "sent",
  "email.delivered": "delivered",
  "email.delivery_delayed": "delayed",
  "email.bounced": "bounced",
  "email.failed": "failed",
  "email.complained": "complained",
};

// Out-of-order protection (spec review item 6): a coarse ordering of the
// delivery lifecycle. A newly-arrived event only advances/overwrites
// current state if it is not older (by occurred_at) than the last event
// this row actually applied -- see applyDeliveryEvent() below. This rank
// is a secondary, defense-in-depth signal (an event that would REGRESS
// the rank, e.g. a late 'sent' arriving after 'delivered', is rejected
// even if its timestamp were somehow equal/newer -- corrupted/duplicated
// provider data should never un-deliver a delivered email).
const STATE_RANK: Record<string, number> = { sent: 1, delivered: 2, delayed: 2, bounced: 3, failed: 3, complained: 3 };

type ResendWebhookPayload = {
  type: string;
  created_at: string;
  data: {
    email_id: string;
    [key: string]: unknown;
  };
};

export async function POST(req: Request) {
  const secret = process.env.RESEND_WEBHOOK_SECRET;
  if (!secret) {
    // Never accept an unsigned/unverified payload (spec section 24) --
    // with no secret configured, verification is impossible, so the only
    // honest response is a controlled rejection, not a silent accept.
    console.error("[resend-webhook] RESEND_WEBHOOK_SECRET is not configured -- rejecting webhook.");
    return NextResponse.json({ error: "Webhook not configured." }, { status: 503 });
  }

  const rawBody = await req.text();
  const svixId = req.headers.get("svix-id");
  const svixTimestamp = req.headers.get("svix-timestamp");
  const svixSignature = req.headers.get("svix-signature");
  if (!svixId || !svixTimestamp || !svixSignature) {
    return NextResponse.json({ error: "Missing signature headers." }, { status: 400 });
  }

  let payload: ResendWebhookPayload;
  try {
    const wh = new Webhook(secret);
    // Verification happens here, on the raw body, before any parsing of
    // application-level fields is trusted for anything beyond this check.
    payload = wh.verify(rawBody, { "svix-id": svixId, "svix-timestamp": svixTimestamp, "svix-signature": svixSignature }) as ResendWebhookPayload;
  } catch (err) {
    if (err instanceof WebhookVerificationError) {
      console.warn("[resend-webhook] signature verification failed.");
      return NextResponse.json({ error: "Invalid signature." }, { status: 401 });
    }
    console.error("[resend-webhook] unexpected verification error:", err instanceof Error ? err.message : err);
    return NextResponse.json({ error: "Could not verify webhook." }, { status: 400 });
  }

  const deliveryStatus = EVENT_TYPE_TO_DELIVERY_STATUS[payload.type];
  if (!deliveryStatus) {
    // An event type this app doesn't track yet (e.g. email.opened/clicked,
    // or domain.updated -- see spec review item 9: domain status changes
    // are NOT processed via webhook this phase, Check Verification
    // polling remains the sole authority) -- acknowledge so Resend doesn't
    // retry forever, but do nothing with it.
    return NextResponse.json({ ok: true, ignored: true });
  }

  const providerEmailId = payload.data?.email_id;
  if (!providerEmailId) {
    return NextResponse.json({ ok: true, ignored: true });
  }

  const service = createServiceRoleClient();

  // Correlate by the provider's own email id (spec section 22) -- never by
  // subject/recipient matching.
  const { data: emailRow } = await service.from("email_send_log").select("id, organization_id, last_event_at").eq("provider_message_id", providerEmailId).maybeSingle();
  if (!emailRow) {
    // A webhook for an email this app didn't send (or one older than this
    // phase's migration) -- acknowledge, do nothing.
    return NextResponse.json({ ok: true, unmatched: true });
  }

  // Idempotency (spec review item 6, second half): provider_event_id is
  // ALWAYS the verified svix-id from this already-signature-checked
  // request -- never a locally synthesized approximation (e.g. never a
  // hash of the body, never a generated uuid). A UNIQUE index on it means
  // a retried delivery of the exact same event is a harmless no-op insert
  // conflict, never duplicate history or a re-applied timestamp.
  const occurredAt = payload.created_at ?? new Date().toISOString();
  const { error: insertEventError } = await service.from("email_send_log_events").insert({
    email_send_log_id: emailRow.id,
    organization_id: emailRow.organization_id,
    provider_event_id: svixId,
    event_type: payload.type,
    occurred_at: occurredAt,
    // Small, curated, non-sensitive subset only -- never the full raw
    // payload (spec section 26).
    payload_metadata: {
      bounce_type: (payload.data.bounce as { type?: string } | undefined)?.type ?? null,
      complaint_type: (payload.data.complaint_feedback_type as string | undefined) ?? null,
    },
  });
  if (insertEventError) {
    // Unique-violation on provider_event_id = genuine duplicate delivery,
    // already processed -- acknowledge without reapplying the status
    // update below.
    if (insertEventError.code === "23505") {
      return NextResponse.json({ ok: true, duplicate: true });
    }
    console.error("[resend-webhook] could not record event:", insertEventError.message);
    return NextResponse.json({ error: "Could not record event." }, { status: 500 });
  }

  await applyDeliveryEvent(service, emailRow.id, emailRow.last_event_at, deliveryStatus, occurredAt, payload);

  return NextResponse.json({ ok: true });
}

// Out-of-order safety (spec review item 6): only advances delivery_status
// if this event is not older than the last one actually applied, AND
// never lets a lower-ranked state (e.g. a late 'sent') overwrite a
// higher-ranked one (e.g. an already-applied 'delivered') even in a
// pathological equal-timestamp case. Example this makes impossible:
//   DELIVERED -> (later receives an older SENT event) -> status becomes SENT
// never happens, because occurred_at is checked AND the rank of 'sent'
// (1) is lower than 'delivered' (2).
async function applyDeliveryEvent(
  service: ReturnType<typeof createServiceRoleClient>,
  emailSendLogId: string,
  lastEventAt: string | null,
  deliveryStatus: string,
  occurredAt: string,
  payload: ResendWebhookPayload
) {
  if (lastEventAt) {
    const { data: current } = await service.from("email_send_log").select("delivery_status").eq("id", emailSendLogId).maybeSingle();
    const currentRank = current?.delivery_status ? (STATE_RANK[current.delivery_status] ?? 0) : 0;
    const incomingRank = STATE_RANK[deliveryStatus] ?? 0;
    const isOlder = new Date(occurredAt).getTime() < new Date(lastEventAt).getTime();
    const isLowerRank = incomingRank < currentRank;
    if (isOlder || isLowerRank) {
      console.warn(`[resend-webhook] ignoring out-of-order/regressive event for ${emailSendLogId}: incoming=${deliveryStatus}@${occurredAt}, last_event_at=${lastEventAt}, current_rank=${currentRank}`);
      return;
    }
  }

  const statusTimestampColumn: Record<string, string> = {
    delivered: "delivered_at",
    delayed: "delivery_delayed_at",
    bounced: "bounced_at",
    failed: "delivery_failed_at",
    complained: "complained_at",
  };
  const update: Record<string, unknown> = { delivery_status: deliveryStatus, last_event_at: occurredAt };
  const tsColumn = statusTimestampColumn[deliveryStatus];
  if (tsColumn) update[tsColumn] = occurredAt;
  if (deliveryStatus === "bounced" || deliveryStatus === "failed") {
    const reason = payload.data.bounce as { message?: string } | undefined;
    if (reason?.message) update.error_code = reason.message.slice(0, 200);
  }

  const { error: updateError } = await service.from("email_send_log").update(update).eq("id", emailSendLogId);
  if (updateError) console.error("[resend-webhook] could not update delivery status:", updateError.message);
}
