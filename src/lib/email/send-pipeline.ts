import "server-only";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { sendTransactionalEmail, EMAIL_PROVIDER_CONFIGURED, FRIENDLY_SEND_ERROR, type EmailAttachment } from "@/lib/email/provider";
import { resolveEmailSender } from "@/lib/email/sender-resolver";
import { verifyEntityOwnership, type EmailAuthorizationContext, type OwnedEntityIds } from "@/lib/email/authorization";
import type { EmailPurpose } from "@/lib/email/purposes";

// ============================================================================
// The ONE authoritative server-side send pipeline (spec section 16). Every
// tenant/business email in this app calls sendTenantEmail() -- no module
// builds its own sender address, its own email_send_log row, or calls
// sendTransactionalEmail()/Resend directly.
//
// This table is STILL PHYSICALLY NAMED email_send_log (see 0064's own
// header comment for why the earlier draft's rename was reverted) --
// referred to as "the ledger" or "the outbound email log" in prose here,
// but every query below uses its real name.
//
// Pipeline:
//   caller obtains an EmailAuthorizationContext from
//     resolveEmailAuthorizationContext() (src/lib/email/authorization.ts)
//     -- the ONLY way organizationId enters this module (spec review item 2)
//   -> verify entity ownership (verifyEntityOwnership())
//   -> validate recipients
//   -> resolve sender (org-scoped, gated on sending_enabled -- see
//      sender-resolver.ts, spec review item 2)
//   -> idempotency: reserve or reuse a 'queued' row (spec review items 4/5)
//   -> render + call Resend, WITH the same idempotency key passed as
//      Resend's own Idempotency-Key header
//   -> durably record provider_message_id THE MOMENT it's known, before
//      any other bookkeeping (spec review item 1's "known-sent" case
//      below depends on this actually being reachable)
//   -> finalize the reserved row to sent/failed
//   -> return typed result
// ============================================================================

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// Spec review item 1's three-tier retry policy for a 'queued' reservation:
const IN_PROGRESS_MS = 2 * 60 * 1000; // < 2min: another request is plausibly still mid-flight -- block as a duplicate click
const PROVIDER_IDEMPOTENCY_WINDOW_MS = 24 * 60 * 60 * 1000; // 2min-24h: Resend's own Idempotency-Key still covers a retry at the provider, so it's safe to reuse the same key automatically
// >= 24h with no provider_message_id: Resend's idempotency window has
// expired -- an automatic retry using the same key no longer has ANY
// provider-side protection against duplicating a real send the app simply
// lost track of. This is UNCERTAIN, not failed: never auto-retry here.

export type SendTenantEmailArgs = {
  authContext: EmailAuthorizationContext;
  emailPurpose: EmailPurpose;
  to: string[];
  cc?: string[];
  bcc?: string[];
  subject: string;
  text: string;
  attachments?: EmailAttachment[];

  // Generic linkage (kept for parity with pre-Phase-2F email_send_log rows).
  entityType?: string;
  entityId?: string;

  // Typed entity linkage (spec sections 18/19) -- pass only what's
  // relevant. Independently re-verified against authContext.organizationId
  // inside this function (spec review item 2) -- a mismatched id is a hard
  // error, never silently dropped or silently trusted.
  entities?: OwnedEntityIds;

  sentBy: string | null;

  /**
   * Optional. The BASE idempotency key, WITHOUT a resend-sequence suffix
   * -- e.g. `billing_packet_sent:${invoiceId}:v${packetVersion}`. Bake a
   * document version into it (spec section 34) so a new version is always
   * a fresh key.
   *
   * When provided, this becomes a genuine reservation (spec review items
   * 1/4/5) -- see reserveLedgerRow()'s own header comment for the full
   * retry-state decision tree. Omit entirely for flows with no natural
   * version concept (e.g. the toolbar Email dialog), where idempotency
   * protection is intentionally skipped.
   */
  idempotencyBaseKey?: string;
  /**
   * Explicit user-initiated resend/"Send Updated Version" (or "Send
   * Again" after an uncertain prior attempt, spec review item 1) action
   * -- computes the NEXT resend sequence for idempotencyBaseKey (one past
   * the highest sequence used by ANY prior attempt at this key, sent or
   * not), so an intentional resend is never blocked by -- or collides
   * with -- an earlier attempt at the same key. Omit/false for an
   * ordinary Send click, where sequence is always 0.
   */
  isExplicitResend?: boolean;

  templateKey?: string;
  metadata?: Record<string, unknown>;
};

export type SendTenantEmailResult =
  | { ok: true; emailSendLogId: string; providerMessageId: string | null; senderSource: "platform" | "tenant_verified" }
  | { ok: false; error: string; duplicate?: boolean; inProgress?: boolean; uncertain?: boolean; existingEmailSendLogId?: string };

function validateRecipients(addresses: string[], label: string): string | null {
  if (addresses.length === 0) return null;
  for (const addr of addresses) {
    if (!EMAIL_RE.test(addr.trim())) return `"${addr}" is not a valid ${label} email address.`;
  }
  return null;
}

// Resend's Idempotency-Key header has its own format expectations
// (reasonable length, no whitespace/control characters) -- sanitize
// defensively rather than assume every caller-built base key is already
// provider-safe.
function sanitizeForProviderKey(key: string): string {
  return key.replace(/\s+/g, "-").replace(/[^a-zA-Z0-9:_-]/g, "").slice(0, 200);
}

type ReservationOutcome = { ok: true; id: string } | { ok: false; error: string; duplicate?: boolean; inProgress?: boolean; uncertain?: boolean; existingId?: string };

/**
 * Spec review item 1 -- the full retry-state decision tree for a
 * 'queued' reservation found at this idempotency key:
 *
 *   provider_message_id IS SET (any status)
 *     -> KNOWN-SENT. The provider durably recorded accepting this send
 *        (see the two-phase persist in sendTenantEmail below) even if
 *        this row's own `status` never made it to 'sent' -- heal the
 *        row and treat as a duplicate. NEVER re-sent, at any age.
 *
 *   status = 'sent'
 *     -> duplicate, blocked (unchanged).
 *
 *   status = 'queued', age < 2 minutes
 *     -> IN-PROGRESS, blocked -- another request is plausibly still
 *        mid-flight.
 *
 *   status = 'queued', 2 minutes <= age < 24 hours
 *     -> safe automatic retry, REUSING the same key -- Resend's own
 *        Idempotency-Key window (24h) still protects against the
 *        provider actually having accepted the original request.
 *
 *   status = 'queued', age >= 24 hours
 *     -> UNCERTAIN. The provider's idempotency window has expired, so an
 *        automatic retry with the same key has NO provider-side
 *        protection left -- if the original request actually succeeded
 *        silently, retrying now could send a genuine duplicate to the
 *        customer. Never auto-retried; the caller must make an explicit
 *        "Send Again" decision (isExplicitResend=true), which allocates
 *        a NEW sequence rather than reusing this key at all.
 *
 *   status IN ('failed', 'blocked'), any age
 *     -> safe retry, REUSING the same key -- these mean the provider
 *        definitively rejected/never received the request (no ambiguity
 *        to age out of).
 */
async function reserveLedgerRow(
  service: ReturnType<typeof createServiceRoleClient>,
  organizationId: string,
  fullIdempotencyKey: string,
  baseRow: Record<string, unknown>
): Promise<ReservationOutcome> {
  const { data: existing } = await service
    .from("email_send_log")
    .select("id, status, updated_at, provider_message_id")
    .eq("organization_id", organizationId)
    .eq("idempotency_key", fullIdempotencyKey)
    .maybeSingle();

  if (existing) {
    if (existing.provider_message_id) {
      // Known-sent, regardless of `status` or age -- heal the row if it
      // never got finalized, and never re-send.
      if (existing.status !== "sent") {
        await service.from("email_send_log").update({ status: "sent", delivery_status: "sent", error: null, idempotency_active: true }).eq("id", existing.id);
      }
      return { ok: false, error: "This email was already sent. Use Resend / Send Updated Version to send it again.", duplicate: true, existingId: existing.id };
    }
    if (existing.status === "sent") {
      // Defensive: status says sent but provider_message_id is somehow
      // missing (pre-Phase-2F row, or a row from before this durability
      // fix existed) -- still a known send, don't retry it.
      return { ok: false, error: "This email was already sent. Use Resend / Send Updated Version to send it again.", duplicate: true, existingId: existing.id };
    }

    if (existing.status === "queued") {
      const ageMs = Date.now() - new Date(existing.updated_at).getTime();
      if (ageMs < IN_PROGRESS_MS) {
        return { ok: false, error: "A send for this is already in progress. Please wait a moment and try again.", inProgress: true, existingId: existing.id };
      }
      if (ageMs >= PROVIDER_IDEMPOTENCY_WINDOW_MS) {
        // >= 24h, no provider_message_id -- outside Resend's own
        // idempotency window. Mark the row so Email History reflects
        // this honestly, and require an explicit resend rather than
        // silently treating it as failed.
        await service.from("email_send_log").update({ delivery_status: "uncertain" }).eq("id", existing.id);
        return {
          ok: false,
          error: "Delivery status of the previous send could not be confirmed. Review the email history before sending again.",
          uncertain: true,
          existingId: existing.id,
        };
      }
      // 2min <= age < 24h -- safe automatic retry, reusing this row/key.
    }

    // failed/blocked, or queued-and-safely-retryable -- reuse this exact
    // row rather than inserting a new one (spec review item 5: never
    // permanently blocked). idempotency_active: true re-arms the partial
    // unique index's protection for this key (see this file's header
    // comment on the 42P17 fix).
    const { error: updateError } = await service.from("email_send_log").update({ ...baseRow, status: "queued", error: null, delivery_status: null, idempotency_active: true }).eq("id", existing.id);
    if (updateError) return { ok: false, error: "Could not prepare this email for sending. Please try again." };
    return { ok: true, id: existing.id };
  }

  const { data: inserted, error: insertError } = await service
    .from("email_send_log")
    .insert({ ...baseRow, organization_id: organizationId, idempotency_key: fullIdempotencyKey, status: "queued", idempotency_active: true })
    .select("id")
    .single();
  if (insertError) {
    // Unique-violation on the partial (queued|sent) index = a genuine
    // concurrent race lost to another request reserving the same key
    // first -- treat identically to "already in progress", never crash.
    if (insertError.code === "23505") {
      return { ok: false, error: "A send for this is already in progress. Please wait a moment and try again.", inProgress: true };
    }
    return { ok: false, error: "Could not prepare this email for sending. Please try again." };
  }
  return { ok: true, id: inserted.id };
}

// Considers EVERY prior attempt at this base key, regardless of outcome
// (sent, failed, blocked, or stuck 'uncertain') -- an explicit resend
// must never collide with ANY previously-used sequence, not just
// successful ones, otherwise a resend after an uncertain 24h+ timeout
// would reuse the exact key that's ambiguous in the first place.
async function nextResendSequence(service: ReturnType<typeof createServiceRoleClient>, organizationId: string, baseKey: string): Promise<number> {
  const { data } = await service.from("email_send_log").select("idempotency_key").eq("organization_id", organizationId).like("idempotency_key", `${baseKey}:%`);
  let max = -1;
  for (const row of data ?? []) {
    const suffix = row.idempotency_key?.slice(baseKey.length + 1);
    const n = suffix ? Number(suffix) : NaN;
    if (Number.isFinite(n) && n > max) max = n;
  }
  return max + 1;
}

export async function sendTenantEmail(args: SendTenantEmailArgs): Promise<SendTenantEmailResult> {
  const service = createServiceRoleClient();
  const organizationId = args.authContext.organizationId;

  const to = args.to.map((a) => a.trim()).filter(Boolean);
  const cc = (args.cc ?? []).map((a) => a.trim()).filter(Boolean);
  const bcc = (args.bcc ?? []).map((a) => a.trim()).filter(Boolean);

  if (to.length === 0) return { ok: false, error: "No recipient email address was provided." };
  const toError = validateRecipients(to, "recipient");
  if (toError) return { ok: false, error: toError };
  const ccError = validateRecipients(cc, "CC");
  if (ccError) return { ok: false, error: ccError };
  const bccError = validateRecipients(bcc, "BCC");
  if (bccError) return { ok: false, error: bccError };

  // Spec review item 2 -- every entity id is independently re-verified to
  // belong to authContext.organizationId, never trusted as-is.
  const ownership = await verifyEntityOwnership(organizationId, args.entities ?? {});
  if (!ownership.ok) return { ok: false, error: ownership.error };
  const entities = ownership.verified;

  const sender = await resolveEmailSender({ organizationId, emailPurpose: args.emailPurpose });
  const { data: org } = await service.from("organizations").select("name").eq("id", organizationId).maybeSingle();

  const baseRow = {
    entity_type: args.entityType ?? args.emailPurpose,
    entity_id: args.entityId ?? entities.invoiceId ?? entities.loadId ?? entities.dispatchId ?? organizationId,
    recipient: to[0],
    cc: cc.length > 0 ? cc.join(", ") : null,
    subject: args.subject,
    attachment_type: args.attachments && args.attachments.length > 0 ? args.attachments[0].filename : null,
    sender_id: sender.senderId,
    domain_id: sender.domainId,
    sender_source: sender.senderSource,
    from_name: sender.fromName,
    from_email: sender.fromEmail,
    reply_to: sender.replyTo,
    to_addresses: to,
    cc_addresses: cc.length > 0 ? cc : null,
    bcc_addresses: bcc.length > 0 ? bcc : null,
    email_purpose: args.emailPurpose,
    template_key: args.templateKey ?? null,
    load_id: entities.loadId ?? null,
    invoice_id: entities.invoiceId ?? null,
    customer_id: entities.customerId ?? null,
    broker_id: entities.brokerId ?? null,
    dispatch_id: entities.dispatchId ?? null,
    driver_id: entities.driverId ?? null,
    sent_by: args.sentBy,
    metadata: args.metadata ?? {},
  };

  // ---- Idempotency reservation (spec review items 1/4/5) ----
  let ledgerId: string | null = null;
  let fullIdempotencyKey: string | null = null;
  if (args.idempotencyBaseKey) {
    const sequence = args.isExplicitResend ? await nextResendSequence(service, organizationId, args.idempotencyBaseKey) : 0;
    fullIdempotencyKey = `${args.idempotencyBaseKey}:${sequence}`;
    const reservation = await reserveLedgerRow(service, organizationId, fullIdempotencyKey, baseRow);
    if (!reservation.ok) {
      return { ok: false, error: reservation.error, duplicate: reservation.duplicate, inProgress: reservation.inProgress, uncertain: reservation.uncertain, existingEmailSendLogId: reservation.existingId };
    }
    ledgerId = reservation.id;
  }

  if (!EMAIL_PROVIDER_CONFIGURED) {
    if (ledgerId) {
      // idempotency_active: null releases this key's reservation (spec
      // review item 5) -- a 'blocked' attempt never reached the provider,
      // so a later retry must not be permanently stuck behind it.
      await service.from("email_send_log").update({ status: "blocked", error: "Email provider not configured.", idempotency_active: null }).eq("id", ledgerId);
    } else {
      await service.from("email_send_log").insert({ ...baseRow, organization_id: organizationId, status: "blocked", error: "Email provider not configured.", idempotency_key: fullIdempotencyKey });
    }
    return { ok: false, error: "Email provider not configured." };
  }

  // Computed ONCE and reused for both the actual provider call and the
  // persisted provider_idempotency_key column below -- found live during
  // Phase 2F post-migration verification: these had drifted apart.
  // provider_idempotency_key was being persisted as the bare
  // fullIdempotencyKey (this app's own local key), not the sanitized,
  // organizationId-prefixed value actually sent to Resend as its
  // Idempotency-Key header, so a support engineer cross-referencing
  // email_send_log.provider_idempotency_key against Resend's own
  // dashboard/API would never find a match.
  const providerIdempotencyKey = fullIdempotencyKey ? sanitizeForProviderKey(`${organizationId}:${fullIdempotencyKey}`) : undefined;

  let sendResult;
  try {
    sendResult = await sendTransactionalEmail({
      to: to.join(", "),
      cc: cc.length > 0 ? cc.join(", ") : undefined,
      bcc: bcc.length > 0 ? bcc.join(", ") : undefined,
      subject: args.subject,
      text: args.text,
      from: sender.fromHeader,
      replyTo: sender.replyTo ?? undefined,
      organizationName: org?.name ?? "",
      heading: args.subject,
      attachments: args.attachments,
      // Two-layer idempotency (spec review item 4): the SAME key this
      // app uses to reserve/dedupe locally is also sent to Resend as its
      // own Idempotency-Key header, so a retried request that never made
      // it back to update the local row is still deduplicated by the
      // provider itself, not just by this app's own bookkeeping.
      idempotencyKey: providerIdempotencyKey,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "The email provider could not be reached.";
    // idempotency_active: null releases the reservation -- a genuine
    // retry of a failed attempt must never be permanently blocked (spec
    // review item 5).
    if (ledgerId) await service.from("email_send_log").update({ status: "failed", error: message, idempotency_active: null }).eq("id", ledgerId);
    return { ok: false, error: FRIENDLY_SEND_ERROR };
  }

  if (!sendResult.ok) {
    if (ledgerId) {
      await service.from("email_send_log").update({ status: "failed", error: sendResult.error, idempotency_active: null }).eq("id", ledgerId);
    } else {
      await service.from("email_send_log").insert({ ...baseRow, organization_id: organizationId, status: "failed", error: sendResult.error, idempotency_key: fullIdempotencyKey });
    }
    return { ok: false, error: FRIENDLY_SEND_ERROR };
  }

  // Durability checkpoint (spec review item 1): record provider_message_id
  // THE MOMENT it's known, as its own write, before any further
  // bookkeeping. If this process crashes right after this point, the row
  // still durably proves "the provider accepted this" -- reserveLedgerRow's
  // provider_message_id check above (checked before any age-based logic)
  // means a future retry attempt heals the row instead of ever treating it
  // as uncertain or re-sending it.
  const sentAt = new Date().toISOString();
  if (ledgerId) {
    await service.from("email_send_log").update({ provider_message_id: sendResult.providerMessageId }).eq("id", ledgerId);
    // idempotency_active: true is already the value set by the
    // reservation step above in every path that reaches here -- set
    // explicitly again anyway (belt-and-suspenders for this
    // correctness-critical invariant, not relied on to correct a bug).
    await service
      .from("email_send_log")
      .update({ status: "sent", error: null, sent_at: sentAt, delivery_status: "sent", provider_idempotency_key: providerIdempotencyKey, idempotency_active: true })
      .eq("id", ledgerId);
  } else {
    const { data: inserted } = await service
      .from("email_send_log")
      .insert({ ...baseRow, organization_id: organizationId, status: "sent", sent_at: sentAt, provider_message_id: sendResult.providerMessageId, delivery_status: "sent", idempotency_key: fullIdempotencyKey })
      .select("id")
      .single();
    ledgerId = inserted?.id ?? null;
  }

  return { ok: true, emailSendLogId: ledgerId ?? "", providerMessageId: sendResult.providerMessageId, senderSource: sender.senderSource };
}
