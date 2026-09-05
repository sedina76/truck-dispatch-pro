import "server-only";

// =============================================================================
// PHASE D.2 -- Stripe SaaS-subscription sync: the shared, DB-write-free
// normalization + orchestration core used by BOTH the signed webhook route
// (src/app/api/webhooks/stripe/route.ts) and the explicit reconciliation
// server action (src/app/(app)/settings/subscription/actions.ts).
//
// This module holds NO `@/`-aliased imports and NO relative imports on
// purpose: it is the one unit-tested surface (src/lib/stripe/
// subscription-state.test.mjs), so it must load cleanly under `node --test`
// with only `import type Stripe` (stripped at runtime). The real Stripe
// client and the real service-role Supabase client are INJECTED by the thin
// wiring files; tests pass fakes.
//
// D.2.1 AUTHORITATIVE DELETION BOUNDARY: p_mode='deleted' is reachable from
// EXACTLY ONE place -- handleSubscriptionDeleted, for a signed
// customer.subscription.deleted event. A failure to canonically retrieve
// the Stripe Subscription for ANY other event (checkout.session.completed,
// customer.subscription.created / .updated, invoice.paid /
// .payment_failed) or for explicit reconciliation -- resource_missing / 404
// included -- NEVER synthesizes a canceled state, NEVER calls deleted mode,
// NEVER writes billing_records for that attempt; it leaves local lifecycle
// state untouched and fails the webhook claim (retryable). A later
// customer.subscription.deleted is the only thing that cancels.
//
// CONTRACT SOURCE OF TRUTH: supabase/migrations/
// 0127_stripe_reconciliation_and_billing_records_hardening.sql (LIVE,
// 41/41 verified). Everything below conforms to the FINAL live 0127 SQL:
//
//   public.apply_stripe_subscription_state(
//     p_stripe_event_id              text,     -- NULL only for p_mode='reconcile'
//     p_claim_token                  uuid,     -- NULL only for p_mode='reconcile'
//     p_organization_subscription_id uuid,     -- resolved from a STORED mapping, never metadata
//     p_mode                         text,     -- 'apply' | 'deleted' | 'reconcile'
//     p_stripe_customer_id           text,
//     p_stripe_subscription_id       text,
//     p_stripe_checkout_session_id   text,     -- only for checkout.session.completed
//     p_stripe_price_id              text,     -- NULL in 'deleted' mode
//     p_price_interval               text,     -- 'month' | 'year' | NULL
//     p_status                       text,     -- raw Stripe subscription.status; ignored in 'deleted'
//     p_trial_end                    timestamptz,
//     p_current_period_start         timestamptz,
//     p_current_period_end           timestamptz,
//     p_cancel_at_period_end         boolean,
//     p_canceled_at                  timestamptz,
//     p_event_at                     timestamptz,  -- ordering fence value (Stripe event.created)
//     p_secondary_conflict           text,     -- NULL = metadata/client_reference_id agreed
//     p_invoice                      jsonb     -- NULL unless invoice.paid / invoice.payment_failed
//   ) returns text
//
//   return values:
//     'applied' | 'applied_billing_recorded' | 'applied_billing_conflict'
//     'stale_skipped' | 'stale_skipped_billing_recorded'
//     'reconciliation_required' | 'reconciliation_required_billing_recorded'
//     'not_owner' | 'noop'
//
//   p_invoice JSON keys the RPC reads (0127 _stripe_upsert_billing_record +
//   P15): stripe_invoice_id (required, non-empty), stripe_status
//   (NULL or exactly one of open|paid|void|uncollectible -- ANY other
//   non-NULL value makes the RPC RAISE and roll the whole tx back),
//   amount_cents (int, default 0), currency (default 'usd'),
//   invoice_pdf_url, period_start, period_end, paid_at, delinquency_anchor
//   (timestamptz; only consulted while status is past_due/unpaid).
//
//   0119 claim RPC: claim_stripe_webhook_event(p_stripe_event_id, p_type,
//   p_api_version, p_payload jsonb, p_stripe_created_at timestamptz,
//   p_stale_after interval default '15 minutes') -> rows of
//   (result text, claim_token uuid): ('claimed', <uuid>) |
//   ('already_processed', NULL) | ('already_in_progress', NULL).
//   fail_stripe_webhook_event(p_stripe_event_id, p_claim_token, p_error) ->
//   boolean. complete_stripe_webhook_event is NEVER called from here for a
//   claimed-then-RPC event -- 0127's apply RPC completes the claim itself as
//   its last statement. It IS called directly for a legitimately terminal
//   no-op (a one-off invoice, a non-subscription checkout) that was claimed
//   but has no business effect.
// =============================================================================

// ---------------------------------------------------------------------------
// Injected dependency shapes (structural -- the real clients satisfy them;
// tests pass minimal fakes). Method syntax is deliberate: it keeps
// parameter checks bivariant so the richer real client types remain
// assignable.
// ---------------------------------------------------------------------------
export type PgError = { message: string; code?: string } | null | undefined;

export interface StripeSyncDb {
  rpc(fn: string, params: Record<string, unknown>): Promise<{ data: unknown; error: PgError }>;
  from(table: string): StripeSyncDbFrom;
}
interface StripeSyncDbFrom {
  select(columns: string): StripeSyncDbSelect;
}
interface StripeSyncDbSelect {
  eq(column: string, value: string): StripeSyncDbFilter;
}
interface StripeSyncDbFilter {
  maybeSingle(): Promise<{ data: Record<string, unknown> | null; error: PgError }>;
}

export interface StripeSyncApi {
  subscriptions: {
    retrieve(id: string, params?: Record<string, unknown>): Promise<StripeSubscriptionLike>;
    list(params: Record<string, unknown>): Promise<{ data: StripeSubscriptionLike[] }>;
  };
  invoices: {
    retrieve(id: string, params?: Record<string, unknown>): Promise<StripeInvoiceLike>;
  };
}

// Minimal read-only views of the Stripe objects we consume.
export interface StripeSubscriptionLike {
  id: string;
  status: string;
  customer: string | { id: string } | null;
  cancel_at_period_end?: boolean | null;
  canceled_at?: number | null;
  ended_at?: number | null;
  trial_end?: number | null;
  current_period_start?: number | null;
  current_period_end?: number | null;
  metadata?: Record<string, string> | null;
  items?: { data: StripeSubscriptionItemLike[] } | null;
}
export interface StripeSubscriptionItemLike {
  current_period_start?: number | null;
  current_period_end?: number | null;
  price?: {
    id?: string | null;
    recurring?: { interval?: string | null } | null;
  } | null;
}
export interface StripeInvoiceLike {
  id?: string | null;
  status?: string | null;
  customer?: string | { id: string } | null;
  subscription?: string | { id: string } | null;
  parent?: { subscription_details?: { subscription?: string | { id: string } | null } | null } | null;
  amount_paid?: number | null;
  amount_due?: number | null;
  currency?: string | null;
  invoice_pdf?: string | null;
  period_start?: number | null;
  period_end?: number | null;
  created?: number | null;
  metadata?: Record<string, string> | null;
  status_transitions?: { paid_at?: number | null; finalized_at?: number | null } | null;
}

// ---------------------------------------------------------------------------
// Supported MVP event set (section C). Everything else -> signed no-op.
// ---------------------------------------------------------------------------
export const SUPPORTED_EVENT_TYPES: ReadonlySet<string> = new Set([
  "checkout.session.completed",
  "customer.subscription.created",
  "customer.subscription.updated",
  "customer.subscription.deleted",
  "invoice.paid",
  "invoice.payment_failed",
]);

// ---------------------------------------------------------------------------
// Strict Stripe -> TDP subscription_status normalization (section F). The
// TDP enum (0001 + 0119) is an exact 1:1 with Stripe's status domain, so
// this is an allow-list pass-through: anything unrecognized -> null (the
// caller then lets 0127 P12 fail it closed into `invalid_status`).
// ---------------------------------------------------------------------------
const TDP_SUBSCRIPTION_STATUSES: ReadonlySet<string> = new Set([
  "incomplete",
  "incomplete_expired",
  "trialing",
  "active",
  "past_due",
  "unpaid",
  "canceled",
  "paused",
]);

export function normalizeStripeStatus(raw: string | null | undefined): string | null {
  if (typeof raw !== "string") return null;
  return TDP_SUBSCRIPTION_STATUSES.has(raw) ? raw : null;
}

// ---------------------------------------------------------------------------
// Timestamp normalization: Stripe unix-seconds -> ISO-8601 string (or null).
// ---------------------------------------------------------------------------
export function unixToIso(seconds: number | null | undefined): string | null {
  if (typeof seconds !== "number" || !Number.isFinite(seconds) || seconds <= 0) return null;
  return new Date(seconds * 1000).toISOString();
}

export function stripeIdOf(value: string | { id: string } | null | undefined): string | null {
  if (value === null || value === undefined) return null;
  return typeof value === "string" ? value : typeof value.id === "string" ? value.id : null;
}

// ---------------------------------------------------------------------------
// Canonical recurring Price extraction. TDP SaaS subscriptions are exactly
// one recurring item; anything else is a fail-closed structural problem the
// 18-arg RPC shape cannot express (it takes a single p_stripe_price_id), so
// the caller must NOT invoke the RPC -- it fails the claim as retryable.
// ---------------------------------------------------------------------------
export type PriceExtract =
  | { ok: true; priceId: string; interval: string | null }
  | { ok: false; reason: "no_items" | "multiple_items" | "no_recurring_price" };

export function extractCanonicalPrice(sub: StripeSubscriptionLike): PriceExtract {
  const items = sub.items?.data ?? [];
  if (items.length === 0) return { ok: false, reason: "no_items" };
  if (items.length > 1) return { ok: false, reason: "multiple_items" };
  const price = items[0]?.price ?? null;
  const priceId = price?.id;
  if (typeof priceId !== "string" || priceId.length === 0) return { ok: false, reason: "no_recurring_price" };
  const interval = price?.recurring?.interval ?? null;
  return { ok: true, priceId, interval: typeof interval === "string" ? interval : null };
}

// Stripe moved current_period_start/end off the Subscription and onto its
// items around API 2025-03-31; the SDK pinned by this repo is well past
// that. Read item-level first, fall back to any legacy top-level value.
export function currentPeriod(sub: StripeSubscriptionLike): { start: string | null; end: string | null } {
  const item = sub.items?.data?.[0];
  const start = item?.current_period_start ?? sub.current_period_start ?? null;
  const end = item?.current_period_end ?? sub.current_period_end ?? null;
  return { start: unixToIso(start), end: unixToIso(end) };
}

// ---------------------------------------------------------------------------
// resource_missing vs transient classification (section G + D.2.1 repair).
// This is a DIAGNOSTIC distinction ONLY. `resource_missing` does NOT mean
// "the subscription was deleted" and NO caller may treat it as authorization
// to cancel. For every NON-deleted event (checkout.session.completed,
// customer.subscription.created / .updated, invoice.paid /
// .payment_failed) and for explicit reconciliation, ANY canonical-retrieve
// failure -- resource_missing, 404, network, timeout, 5xx, rate-limit,
// auth, permission, malformed -- leaves local lifecycle state UNCHANGED,
// makes NO apply_stripe_subscription_state call, writes NO billing_records
// row, and fails the webhook claim (retryable) with a bounded diagnostic
// code. The ONLY automatic path to p_mode='deleted' is a successfully
// signed customer.subscription.deleted event (which never retrieves).
// ---------------------------------------------------------------------------
export type RetrieveErrorKind = "resource_missing" | "transient";

export function classifyStripeRetrieveError(err: unknown): RetrieveErrorKind {
  const e = (err ?? {}) as { type?: unknown; code?: unknown; statusCode?: unknown };
  if (e.type === "StripeInvalidRequestError" && (e.code === "resource_missing" || e.statusCode === 404)) {
    return "resource_missing";
  }
  return "transient";
}

export type CanonicalSubResult =
  | { ok: true; subscription: StripeSubscriptionLike }
  | { ok: false; kind: RetrieveErrorKind };

export async function retrieveCanonicalSubscription(
  stripe: StripeSyncApi,
  subscriptionId: string
): Promise<CanonicalSubResult> {
  try {
    const subscription = await stripe.subscriptions.retrieve(subscriptionId, {
      expand: ["items.data.price"],
    });
    return { ok: true, subscription };
  } catch (err) {
    logStripeDiag("subscription_retrieve_failed", err);
    return { ok: false, kind: classifyStripeRetrieveError(err) };
  }
}

// ---------------------------------------------------------------------------
// Bounded, sanitized diagnostics. NEVER logs the Stripe secret, the
// Stripe-Signature header, a claim token, a full webhook body, or a raw
// Stripe object -- only the small non-sensitive triage fields Stripe puts
// on its error shapes.
// ---------------------------------------------------------------------------
export function logStripeDiag(tag: string, err: unknown): void {
  const e = (err ?? {}) as { type?: unknown; code?: unknown; statusCode?: unknown; requestId?: unknown };
  const detail: Record<string, string> = {};
  if (typeof e.type === "string") detail.type = e.type;
  if (typeof e.code === "string") detail.code = e.code;
  if (typeof e.statusCode === "number") detail.statusCode = String(e.statusCode);
  if (typeof e.requestId === "string") detail.requestId = e.requestId;
  console.error(`[stripe-webhook] ${tag}`, detail);
}

// ---------------------------------------------------------------------------
// The 18 RPC arguments, as a named object. Never carries a caller-derived
// plan_id / billing_cycle -- 0127 derives those in PostgreSQL from
// p_stripe_price_id. p_status is passed RAW (0127 P12 validates it).
// ---------------------------------------------------------------------------
export interface ApplyArgs {
  p_stripe_event_id: string | null;
  p_claim_token: string | null;
  p_organization_subscription_id: string;
  p_mode: "apply" | "deleted" | "reconcile";
  p_stripe_customer_id: string | null;
  p_stripe_subscription_id: string | null;
  p_stripe_checkout_session_id: string | null;
  p_stripe_price_id: string | null;
  p_price_interval: string | null;
  p_status: string | null;
  p_trial_end: string | null;
  p_current_period_start: string | null;
  p_current_period_end: string | null;
  p_cancel_at_period_end: boolean;
  p_canceled_at: string | null;
  p_event_at: string | null;
  p_secondary_conflict: string | null;
  p_invoice: InvoiceFact | null;
}

// p_invoice jsonb, exactly the keys 0127 reads.
export interface InvoiceFact {
  stripe_invoice_id: string;
  stripe_status: "open" | "paid" | "void" | "uncollectible";
  amount_cents: number;
  currency: string;
  invoice_pdf_url: string | null;
  period_start: string | null;
  period_end: string | null;
  paid_at: string | null;
  delinquency_anchor: string | null;
}

export const APPLY_RETURN_VALUES = [
  "applied",
  "applied_billing_recorded",
  "applied_billing_conflict",
  "stale_skipped",
  "stale_skipped_billing_recorded",
  "reconciliation_required",
  "reconciliation_required_billing_recorded",
  "not_owner",
  "noop",
] as const;
export type ApplyReturn = (typeof APPLY_RETURN_VALUES)[number];

// ---------------------------------------------------------------------------
// Build the p_invoice fact for invoice.paid / invoice.payment_failed.
// FROZEN status mapping: invoice.paid -> 'paid', invoice.payment_failed ->
// 'open'. The raw Stripe invoice.status is NEVER forwarded, and
// 'payment_failed' is NEVER sent as a billing_records.status.
// ---------------------------------------------------------------------------
export function buildInvoiceFact(
  eventType: "invoice.paid" | "invoice.payment_failed",
  inv: StripeInvoiceLike,
  eventCreated: number | null | undefined
): InvoiceFact | null {
  const id = typeof inv.id === "string" && inv.id.length > 0 ? inv.id : null;
  if (!id) return null;

  const paid = eventType === "invoice.paid";
  const amount = paid ? inv.amount_paid : inv.amount_due;

  return {
    stripe_invoice_id: id,
    stripe_status: paid ? "paid" : "open",
    amount_cents: typeof amount === "number" && Number.isFinite(amount) ? Math.trunc(amount) : 0,
    currency: typeof inv.currency === "string" && inv.currency.length > 0 ? inv.currency : "usd",
    invoice_pdf_url: typeof inv.invoice_pdf === "string" ? inv.invoice_pdf : null,
    period_start: unixToIso(inv.period_start),
    period_end: unixToIso(inv.period_end),
    paid_at: paid ? unixToIso(inv.status_transitions?.paid_at) : null,
    // Only consulted by 0127 P15 while the subscription status is
    // past_due/unpaid -- the best Stripe-authoritative "the bill came due"
    // timestamp, so a delayed webhook delivery never inflates the 7-day
    // grace. Null for invoice.paid (recovery clears past_due_since anyway).
    delinquency_anchor: paid
      ? null
      : unixToIso(inv.status_transitions?.finalized_at ?? inv.created ?? eventCreated),
  };
}

export function invoiceSubscriptionId(inv: StripeInvoiceLike): string | null {
  return stripeIdOf(inv.subscription) ?? stripeIdOf(inv.parent?.subscription_details?.subscription);
}

// ---------------------------------------------------------------------------
// Durable-mapping-only organization resolution (section D). NEVER metadata,
// email, name, or fuzzy matching. Metadata may only CORROBORATE later
// (p_secondary_conflict). The three columns are each UNIQUE on
// organization_subscriptions, so in a healthy world all present lookups
// point at the same row; a disagreement is a fail-closed conflict.
// ---------------------------------------------------------------------------
export type OrgRowResolution =
  | { kind: "resolved"; row: OrgSubscriptionRow }
  | { kind: "unresolved" }
  | { kind: "conflict"; detail: string }
  | { kind: "db_error"; detail: string };

export interface OrgSubscriptionRow {
  id: string;
  organization_id: string;
}

export async function resolveOrgSubscriptionRow(
  db: StripeSyncDb,
  lookups: { subscriptionId?: string | null; checkoutSessionId?: string | null; customerId?: string | null }
): Promise<OrgRowResolution> {
  const attempts: Array<{ column: string; value: string }> = [];
  if (lookups.subscriptionId) attempts.push({ column: "stripe_subscription_id", value: lookups.subscriptionId });
  if (lookups.checkoutSessionId) attempts.push({ column: "stripe_checkout_session_id", value: lookups.checkoutSessionId });
  if (lookups.customerId) attempts.push({ column: "stripe_customer_id", value: lookups.customerId });
  if (attempts.length === 0) return { kind: "unresolved" };

  const found = new Map<string, OrgSubscriptionRow>();
  for (const a of attempts) {
    const { data, error } = await db
      .from("organization_subscriptions")
      .select("id, organization_id")
      .eq(a.column, a.value)
      .maybeSingle();
    if (error) return { kind: "db_error", detail: `${a.column}:${error.code ?? "err"}` };
    if (data && typeof data.id === "string" && typeof data.organization_id === "string") {
      found.set(data.id, { id: data.id, organization_id: data.organization_id });
    }
  }

  if (found.size === 0) return { kind: "unresolved" };
  if (found.size > 1) return { kind: "conflict", detail: "durable_mapping_disagreement" };
  return { kind: "resolved", row: [...found.values()][0] };
}

// Compute the SECONDARY assertion token 0127 P9 consumes. NEVER used to
// resolve identity -- only to corroborate an already-resolved row. Absence
// of metadata is NOT a conflict.
export function computeSecondaryConflict(
  resolvedOrgId: string,
  seen: { metaOrgId?: string | null; clientReferenceId?: string | null; sessionCustomer?: string | null; subCustomer?: string | null }
): string | null {
  if (typeof seen.metaOrgId === "string" && seen.metaOrgId.length > 0 && seen.metaOrgId !== resolvedOrgId) {
    return "metadata_org_id_mismatch";
  }
  if (
    typeof seen.clientReferenceId === "string" &&
    seen.clientReferenceId.length > 0 &&
    seen.clientReferenceId !== resolvedOrgId
  ) {
    return "client_reference_id_mismatch";
  }
  if (
    typeof seen.sessionCustomer === "string" &&
    typeof seen.subCustomer === "string" &&
    seen.sessionCustomer !== seen.subCustomer
  ) {
    return "session_customer_mismatch";
  }
  return null;
}

// ---------------------------------------------------------------------------
// Assemble ApplyArgs from a canonical Subscription (apply mode).
// ---------------------------------------------------------------------------
export function buildApplyArgsFromSubscription(args: {
  mode: "apply" | "reconcile";
  eventId: string | null;
  claimToken: string | null;
  rowId: string;
  sub: StripeSubscriptionLike;
  priceId: string;
  priceInterval: string | null;
  checkoutSessionId: string | null;
  eventAt: string | null;
  secondaryConflict: string | null;
  invoice: InvoiceFact | null;
}): ApplyArgs {
  const period = currentPeriod(args.sub);
  return {
    p_stripe_event_id: args.eventId,
    p_claim_token: args.claimToken,
    p_organization_subscription_id: args.rowId,
    p_mode: args.mode,
    p_stripe_customer_id: stripeIdOf(args.sub.customer),
    p_stripe_subscription_id: args.sub.id,
    p_stripe_checkout_session_id: args.checkoutSessionId,
    p_stripe_price_id: args.priceId,
    p_price_interval: args.priceInterval,
    p_status: typeof args.sub.status === "string" ? args.sub.status : null,
    p_trial_end: unixToIso(args.sub.trial_end),
    p_current_period_start: period.start,
    p_current_period_end: period.end,
    p_cancel_at_period_end: args.sub.cancel_at_period_end === true,
    p_canceled_at: unixToIso(args.sub.canceled_at),
    p_event_at: args.eventAt,
    p_secondary_conflict: args.secondaryConflict,
    p_invoice: args.invoice,
  };
}

// Assemble ApplyArgs for the frozen deleted-mode contract (section J).
// Reached from EXACTLY ONE call site -- handleSubscriptionDeleted, for a
// signed customer.subscription.deleted event. No canonical retrieve is
// required (the signed event object is authoritative); p_status/p_price are
// ignored by 0127 in this mode. canceledAt is the best authoritative
// timestamp available. NOTHING else may reach deleted mode -- a
// canonical-retrieve failure on any other event never lands here (D.2.1).
export function buildDeletedArgs(args: {
  eventId: string;
  claimToken: string;
  rowId: string;
  customerId: string | null;
  subscriptionId: string | null;
  canceledAt: string | null;
  eventAt: string | null;
  secondaryConflict: string | null;
  invoice: InvoiceFact | null;
}): ApplyArgs {
  return {
    p_stripe_event_id: args.eventId,
    p_claim_token: args.claimToken,
    p_organization_subscription_id: args.rowId,
    p_mode: "deleted",
    p_stripe_customer_id: args.customerId,
    p_stripe_subscription_id: args.subscriptionId,
    p_stripe_checkout_session_id: null,
    p_stripe_price_id: null,
    p_price_interval: null,
    p_status: "canceled",
    p_trial_end: null,
    p_current_period_start: null,
    p_current_period_end: null,
    p_cancel_at_period_end: false,
    p_canceled_at: args.canceledAt,
    p_event_at: args.eventAt,
    p_secondary_conflict: args.secondaryConflict,
    p_invoice: args.invoice,
  };
}

// ---------------------------------------------------------------------------
// RPC callers.
// ---------------------------------------------------------------------------
export async function callApplyStripeSubscriptionState(
  db: StripeSyncDb,
  args: ApplyArgs
): Promise<{ ok: true; result: ApplyReturn } | { ok: false; detail: string }> {
  const { data, error } = await db.rpc("apply_stripe_subscription_state", args as unknown as Record<string, unknown>);
  if (error) {
    logStripeDiag("apply_rpc_error", error);
    return { ok: false, detail: (error as { code?: string }).code ?? "rpc_error" };
  }
  const result = typeof data === "string" ? data : Array.isArray(data) ? String(data[0]) : String(data);
  if (!(APPLY_RETURN_VALUES as readonly string[]).includes(result)) {
    return { ok: false, detail: `unexpected_rpc_return:${result}` };
  }
  return { ok: true, result: result as ApplyReturn };
}

export interface ClaimResult {
  result: "claimed" | "already_processed" | "already_in_progress" | "error";
  claimToken: string | null;
}

export async function claimWebhookEvent(db: StripeSyncDb, event: MinimalEvent): Promise<ClaimResult> {
  const { data, error } = await db.rpc("claim_stripe_webhook_event", {
    p_stripe_event_id: event.id,
    p_type: event.type,
    p_api_version: event.api_version ?? null,
    p_payload: event as unknown,
    p_stripe_created_at: unixToIso(event.created),
  });
  if (error) {
    logStripeDiag("claim_rpc_error", error);
    return { result: "error", claimToken: null };
  }
  const row = Array.isArray(data) ? (data[0] as Record<string, unknown> | undefined) : (data as Record<string, unknown> | null);
  const result = row && typeof row.result === "string" ? row.result : "";
  const claimToken = row && typeof row.claim_token === "string" ? row.claim_token : null;
  if (result === "claimed" && claimToken) return { result: "claimed", claimToken };
  if (result === "already_processed") return { result: "already_processed", claimToken: null };
  if (result === "already_in_progress") return { result: "already_in_progress", claimToken: null };
  return { result: "error", claimToken: null };
}

export async function failWebhookEvent(
  db: StripeSyncDb,
  eventId: string,
  claimToken: string,
  reason: string
): Promise<void> {
  const { error } = await db.rpc("fail_stripe_webhook_event", {
    p_stripe_event_id: eventId,
    p_claim_token: claimToken,
    p_error: reason.slice(0, 300),
  });
  if (error) logStripeDiag("fail_rpc_error", error);
}

export async function completeWebhookEvent(db: StripeSyncDb, eventId: string, claimToken: string): Promise<void> {
  const { error } = await db.rpc("complete_stripe_webhook_event", {
    p_stripe_event_id: eventId,
    p_claim_token: claimToken,
  });
  if (error) logStripeDiag("complete_rpc_error", error);
}

// ---------------------------------------------------------------------------
// The webhook processing core (section A/C/H-M). Signature verification has
// ALREADY happened in the route before this is called -- this function
// never sees the raw body or the signature.
// ---------------------------------------------------------------------------
export interface MinimalEvent {
  id: string;
  type: string;
  api_version?: string | null;
  created?: number | null;
  data: { object: Record<string, unknown> };
}

export interface WebhookResponse {
  status: number;
  body: Record<string, unknown>;
}

// Pure route preflight (section A steps 1 + 3). The route calls this BEFORE
// touching the raw body's contents or the DB. It never sees the secret's
// value beyond "is it a non-empty string". `constructEvent` throwing ->
// HTTP 400 is handled directly in the route (a single Stripe-SDK call).
export function preflightWebhookRequest(input: {
  secret: string | undefined | null;
  signature: string | null;
}): { ok: true } | { ok: false; status: number; error: string } {
  if (typeof input.secret !== "string" || input.secret.trim() === "") {
    return { ok: false, status: 503, error: "webhook_not_configured" };
  }
  if (typeof input.signature !== "string" || input.signature.length === 0) {
    return { ok: false, status: 400, error: "missing_signature" };
  }
  return { ok: true };
}

export async function processStripeEvent(
  event: MinimalEvent,
  deps: { stripe: StripeSyncApi; db: StripeSyncDb }
): Promise<WebhookResponse> {
  // C -- unsupported signed events are an acknowledged no-op, with ZERO DB
  // work (not even a claim).
  if (!SUPPORTED_EVENT_TYPES.has(event.type)) {
    return { status: 200, body: { ok: true, ignored: true, type: event.type } };
  }

  // M -- claim FIRST (after signature, which the route already did).
  const claim = await claimWebhookEvent(deps.db, event);
  if (claim.result === "error") {
    return { status: 500, body: { ok: false, error: "claim_failed" } };
  }
  if (claim.result === "already_processed") {
    return { status: 200, body: { ok: true, duplicate: true } };
  }
  if (claim.result === "already_in_progress") {
    return { status: 200, body: { ok: true, in_progress: true } };
  }
  const token = claim.claimToken as string;

  try {
    const outcome = await dispatchClaimedEvent(event, token, deps);
    return outcome;
  } catch (err) {
    // Unexpected throw around (not inside) the atomic RPC -- fail the claim
    // so 0119's stale-reclaim / Stripe redelivery can retry it.
    logStripeDiag("event_dispatch_threw", err);
    await failWebhookEvent(deps.db, event.id, token, "handler_exception");
    return { status: 500, body: { ok: false, error: "processing_failed" } };
  }
}

// Map a 0127 RPC return value to an HTTP response. The RPC has ALREADY
// completed or failed the claim itself; we never touch the claim here.
function mapRpcReturn(result: ApplyReturn): WebhookResponse {
  switch (result) {
    case "applied":
    case "applied_billing_recorded":
    case "stale_skipped":
    case "stale_skipped_billing_recorded":
      return { status: 200, body: { ok: true, result } };
    case "applied_billing_conflict":
      // Subscription state WAS applied and the claim WAS completed; an
      // invoice-ownership conflict was flagged for reconciliation. Not a
      // retry situation -- surface it, don't hide it.
      console.error("[stripe-webhook] applied_billing_conflict -- invoice ownership flagged for reconciliation");
      return { status: 200, body: { ok: true, result, reconciliation_flagged: true } };
    case "reconciliation_required":
    case "reconciliation_required_billing_recorded":
      // The RPC took the CONFLICT PATH and fail_'d the claim (retryable).
      // Return non-2xx so Stripe redelivers within its retry window -- if a
      // human fixes the underlying cause, the redelivery applies cleanly;
      // otherwise the durable reconciliation_required_at marker + the
      // explicit reconcile action are the recovery.
      console.error("[stripe-webhook] reconciliation_required -- see organization_subscriptions.reconciliation_reason");
      return { status: 500, body: { ok: false, result, reconciliation_required: true } };
    case "not_owner":
      // Another worker owns a fresh claim (or the row vanished and the RPC
      // fail_'d it). Safe idempotent acknowledgement.
      return { status: 200, body: { ok: true, not_owner: true } };
    case "noop":
      return { status: 200, body: { ok: true, result } };
  }
}

async function dispatchClaimedEvent(
  event: MinimalEvent,
  token: string,
  deps: { stripe: StripeSyncApi; db: StripeSyncDb }
): Promise<WebhookResponse> {
  switch (event.type) {
    case "checkout.session.completed":
      return handleCheckoutSessionCompleted(event, token, deps);
    case "customer.subscription.created":
    case "customer.subscription.updated":
      return handleSubscriptionUpsert(event, token, deps);
    case "customer.subscription.deleted":
      return handleSubscriptionDeleted(event, token, deps);
    case "invoice.paid":
    case "invoice.payment_failed":
      return handleInvoiceEvent(event, token, deps);
    default:
      // unreachable -- SUPPORTED_EVENT_TYPES gates entry
      await completeWebhookEvent(deps.db, event.id, token);
      return { status: 200, body: { ok: true, ignored: true } };
  }
}

// ---- shared helpers for the handlers -------------------------------------

async function resolveOrFail(
  event: MinimalEvent,
  token: string,
  db: StripeSyncDb,
  lookups: Parameters<typeof resolveOrgSubscriptionRow>[1]
): Promise<{ ok: true; row: OrgSubscriptionRow } | { ok: false; res: WebhookResponse }> {
  const r = await resolveOrgSubscriptionRow(db, lookups);
  if (r.kind === "resolved") return { ok: true, row: r.row };
  if (r.kind === "db_error") {
    await failWebhookEvent(db, event.id, token, `db_error:${r.detail}`);
    return { ok: false, res: { status: 500, body: { ok: false, error: "db_error" } } };
  }
  if (r.kind === "conflict") {
    await failWebhookEvent(db, event.id, token, `identity_conflict:${r.detail}`);
    return { ok: false, res: { status: 500, body: { ok: false, error: "identity_conflict", detail: r.detail } } };
  }
  // unresolved -- do NOT invent an organization (section D). Retryable:
  // a checkout.session.completed can (rarely) beat our own mapping write.
  await failWebhookEvent(db, event.id, token, "org_unresolved");
  return { ok: false, res: { status: 500, body: { ok: false, error: "org_unresolved" } } };
}

async function applyAndMap(db: StripeSyncDb, args: ApplyArgs): Promise<WebhookResponse> {
  const r = await callApplyStripeSubscriptionState(db, args);
  if (!r.ok) {
    // The RPC threw -> whole tx rolled back -> claim still 'processing'.
    // Non-2xx so Stripe also redelivers (belt-and-suspenders with 0119's
    // 15-minute stale reclaim).
    return { status: 500, body: { ok: false, error: "rpc_exception", detail: r.detail } };
  }
  return mapRpcReturn(r.result);
}

// ---- checkout.session.completed (section H) -----------------------------

async function handleCheckoutSessionCompleted(
  event: MinimalEvent,
  token: string,
  deps: { stripe: StripeSyncApi; db: StripeSyncDb }
): Promise<WebhookResponse> {
  const obj = event.data.object;
  if (obj.mode !== "subscription") {
    // Definitively not ours and will never change -> terminal no-op.
    await completeWebhookEvent(deps.db, event.id, token);
    return { status: 200, body: { ok: true, ignored: true, reason: "not_subscription_mode" } };
  }
  const sessionId = typeof obj.id === "string" ? obj.id : null;
  const sessionSubId = stripeIdOf(obj.subscription as string | { id: string } | null);
  const sessionCustId = stripeIdOf(obj.customer as string | { id: string } | null);
  if (!sessionSubId) {
    await failWebhookEvent(deps.db, event.id, token, "checkout_session_no_subscription");
    return { status: 500, body: { ok: false, error: "checkout_session_no_subscription" } };
  }

  const canon = await retrieveCanonicalSubscription(deps.stripe, sessionSubId);
  if (!canon.ok) {
    // D.2.1: a checkout event whose subscription cannot be canonically
    // retrieved -- for ANY reason, resource_missing included -- is NOT an
    // authoritative deletion. Leave lifecycle state untouched, no apply
    // call, fail the claim (retryable). A later customer.subscription.deleted
    // is the only thing that may cancel.
    const reason = canon.kind === "resource_missing" ? "canonical_subscription_missing" : "canonical_retrieve_transient";
    await failWebhookEvent(deps.db, event.id, token, reason);
    return { status: 500, body: { ok: false, error: reason } };
  }

  const sub = canon.subscription;
  const resolved = await resolveOrFail(event, token, deps.db, {
    subscriptionId: sub.id,
    checkoutSessionId: sessionId,
    customerId: stripeIdOf(sub.customer),
  });
  if (!resolved.ok) return resolved.res;

  const price = extractCanonicalPrice(sub);
  if (!price.ok) {
    await failWebhookEvent(deps.db, event.id, token, `price_${price.reason}`);
    return { status: 500, body: { ok: false, error: `price_${price.reason}` } };
  }

  const secondary = computeSecondaryConflict(resolved.row.organization_id, {
    metaOrgId: readMetaOrgId(obj),
    clientReferenceId: typeof obj.client_reference_id === "string" ? obj.client_reference_id : null,
    sessionCustomer: sessionCustId,
    subCustomer: stripeIdOf(sub.customer),
  });

  const args = buildApplyArgsFromSubscription({
    mode: "apply",
    eventId: event.id,
    claimToken: token,
    rowId: resolved.row.id,
    sub,
    priceId: price.priceId,
    priceInterval: price.interval,
    checkoutSessionId: sessionId,
    eventAt: unixToIso(event.created),
    secondaryConflict: secondary,
    invoice: null,
  });
  return applyAndMap(deps.db, args);
}

// ---- customer.subscription.created / .updated (section I) --------------

async function handleSubscriptionUpsert(
  event: MinimalEvent,
  token: string,
  deps: { stripe: StripeSyncApi; db: StripeSyncDb }
): Promise<WebhookResponse> {
  const obj = event.data.object;
  const subId = typeof obj.id === "string" ? obj.id : null;
  if (!subId) {
    await failWebhookEvent(deps.db, event.id, token, "subscription_event_no_id");
    return { status: 500, body: { ok: false, error: "subscription_event_no_id" } };
  }

  const canon = await retrieveCanonicalSubscription(deps.stripe, subId);
  if (!canon.ok) {
    // D.2.1: created/updated whose canonical subscription cannot be
    // retrieved -- resource_missing included -- is NOT an authoritative
    // deletion. No apply, no synthesized canceled state, fail the claim.
    const reason = canon.kind === "resource_missing" ? "canonical_subscription_missing" : "canonical_retrieve_transient";
    await failWebhookEvent(deps.db, event.id, token, reason);
    return { status: 500, body: { ok: false, error: reason } };
  }

  const sub = canon.subscription;
  const resolved = await resolveOrFail(event, token, deps.db, {
    subscriptionId: sub.id,
    customerId: stripeIdOf(sub.customer),
  });
  if (!resolved.ok) return resolved.res;

  const price = extractCanonicalPrice(sub);
  if (!price.ok) {
    await failWebhookEvent(deps.db, event.id, token, `price_${price.reason}`);
    return { status: 500, body: { ok: false, error: `price_${price.reason}` } };
  }

  const secondary = computeSecondaryConflict(resolved.row.organization_id, {
    metaOrgId: readMetaOrgId(obj),
  });

  const args = buildApplyArgsFromSubscription({
    mode: "apply",
    eventId: event.id,
    claimToken: token,
    rowId: resolved.row.id,
    sub,
    priceId: price.priceId,
    priceInterval: price.interval,
    checkoutSessionId: null,
    eventAt: unixToIso(event.created),
    secondaryConflict: secondary,
    invoice: null,
  });
  return applyAndMap(deps.db, args);
}

// ---- customer.subscription.deleted (section J) ------------------------
// THE ONLY automatic path to p_mode='deleted'. The signed event object is
// authoritative; no canonical retrieve happens here.

async function handleSubscriptionDeleted(
  event: MinimalEvent,
  token: string,
  deps: { stripe: StripeSyncApi; db: StripeSyncDb }
): Promise<WebhookResponse> {
  const obj = event.data.object;
  const subId = typeof obj.id === "string" ? obj.id : null;
  const custId = stripeIdOf(obj.customer as string | { id: string } | null);
  if (!subId) {
    await failWebhookEvent(deps.db, event.id, token, "deleted_event_no_id");
    return { status: 500, body: { ok: false, error: "deleted_event_no_id" } };
  }

  const resolved = await resolveOrFail(event, token, deps.db, {
    subscriptionId: subId,
    customerId: custId,
  });
  if (!resolved.ok) return resolved.res;

  const secondary = computeSecondaryConflict(resolved.row.organization_id, { metaOrgId: readMetaOrgId(obj) });
  const canceledAt = unixToIso(numOr(obj.canceled_at) ?? numOr(obj.ended_at) ?? event.created);

  const args = buildDeletedArgs({
    eventId: event.id,
    claimToken: token,
    rowId: resolved.row.id,
    customerId: custId,
    subscriptionId: subId,
    canceledAt,
    eventAt: unixToIso(event.created),
    secondaryConflict: secondary,
    invoice: null,
  });
  return applyAndMap(deps.db, args);
}

// ---- invoice.paid / invoice.payment_failed (section K) ---------------

async function handleInvoiceEvent(
  event: MinimalEvent,
  token: string,
  deps: { stripe: StripeSyncApi; db: StripeSyncDb }
): Promise<WebhookResponse> {
  const inv = event.data.object as unknown as StripeInvoiceLike;
  const eventType = event.type as "invoice.paid" | "invoice.payment_failed";
  const invSubId = invoiceSubscriptionId(inv);
  if (!invSubId) {
    // A one-off invoice, not SaaS subscription billing -> terminal no-op.
    await completeWebhookEvent(deps.db, event.id, token);
    return { status: 200, body: { ok: true, ignored: true, reason: "one_off_invoice" } };
  }
  const fact = buildInvoiceFact(eventType, inv, event.created);
  if (!fact) {
    await completeWebhookEvent(deps.db, event.id, token);
    return { status: 200, body: { ok: true, ignored: true, reason: "invoice_no_id" } };
  }
  const invCustId = stripeIdOf(inv.customer);

  const canon = await retrieveCanonicalSubscription(deps.stripe, invSubId);
  if (!canon.ok) {
    // D.2.1: if the invoice's subscription cannot be canonically retrieved
    // -- resource_missing included -- canonical ownership for THIS attempt
    // is not established. Do NOT cancel, do NOT write a billing_records row,
    // do NOT call deleted-mode. Fail the claim (retryable); the billing
    // fact can be processed later once canonical identity is available or
    // via a separately authorized recovery path.
    const reason = canon.kind === "resource_missing" ? "canonical_subscription_missing" : "canonical_retrieve_transient";
    await failWebhookEvent(deps.db, event.id, token, reason);
    return { status: 500, body: { ok: false, error: reason } };
  }

  const resolved = await resolveOrFail(event, token, deps.db, {
    subscriptionId: invSubId,
    customerId: invCustId,
  });
  if (!resolved.ok) return resolved.res;

  const sub = canon.subscription;
  const price = extractCanonicalPrice(sub);
  if (!price.ok) {
    await failWebhookEvent(deps.db, event.id, token, `price_${price.reason}`);
    return { status: 500, body: { ok: false, error: `price_${price.reason}` } };
  }
  const secondary = computeSecondaryConflict(resolved.row.organization_id, {
    metaOrgId: readMetaOrgId(inv as unknown as Record<string, unknown>),
  });

  const args = buildApplyArgsFromSubscription({
    mode: "apply",
    eventId: event.id,
    claimToken: token,
    rowId: resolved.row.id,
    sub,
    priceId: price.priceId,
    priceInterval: price.interval,
    checkoutSessionId: null,
    eventAt: unixToIso(event.created),
    secondaryConflict: secondary,
    invoice: fact,
  });
  return applyAndMap(deps.db, args);
}

// ---------------------------------------------------------------------------
// Explicit reconciliation core (section N). Reuses the SAME normalization
// pipeline. p_mode='reconcile' -> p_stripe_event_id / p_claim_token MUST be
// null (0127 rejects otherwise); the RPC re-runs every gate against fresh
// canonical state and is the ONLY mode that clears an identity/authority
// reconciliation_reason. No Customer / Checkout / Subscription is ever
// created here.
// ---------------------------------------------------------------------------
export type ReconcileResult =
  | { ok: true; code: "reconciled"; result: ApplyReturn }
  | { ok: true; code: "no_subscription" }
  | { ok: false; code: ReconcileRefusal; detail?: string };

export type ReconcileRefusal =
  | "not_found"
  | "grandfathered"
  | "billing_not_required"
  | "no_mapping"
  | "multiple_subscriptions"
  | "canonical_retrieve_transient"
  | "canonical_subscription_missing"
  | "identity_conflict"
  | "db_error"
  | "rpc_exception"
  | "reconciliation_required";

export interface ReconcileRow {
  id: string;
  organization_id: string;
  grandfathered_at: string | null;
  stripe_customer_id: string | null;
  stripe_subscription_id: string | null;
  stripe_price_id: string | null;
  billing_required: boolean;
}

export async function reconcileOrganizationSubscription(
  deps: { stripe: StripeSyncApi; db: StripeSyncDb },
  input: { row: ReconcileRow }
): Promise<ReconcileResult> {
  const { row } = input;

  if (row.grandfathered_at !== null) return { ok: false, code: "grandfathered" };
  if (row.billing_required !== true) return { ok: false, code: "billing_not_required" };
  if (!row.stripe_customer_id && !row.stripe_subscription_id) return { ok: false, code: "no_mapping" };

  // Resolve WHICH subscription to reconcile, from durable mappings only.
  let subscriptionId = row.stripe_subscription_id ?? null;
  if (!subscriptionId && row.stripe_customer_id) {
    let list: { data: StripeSubscriptionLike[] };
    try {
      list = await deps.stripe.subscriptions.list({
        customer: row.stripe_customer_id,
        status: "all",
        limit: 2,
        expand: ["data.items.data.price"],
      });
    } catch (err) {
      logStripeDiag("reconcile_list_failed", err);
      return { ok: false, code: "canonical_retrieve_transient" };
    }
    if (list.data.length === 0) return { ok: true, code: "no_subscription" };
    if (list.data.length > 1) return { ok: false, code: "multiple_subscriptions" };
    subscriptionId = list.data[0].id;
  }
  if (!subscriptionId) return { ok: true, code: "no_subscription" };

  const canon = await retrieveCanonicalSubscription(deps.stripe, subscriptionId);

  let args: ApplyArgs;
  if (!canon.ok) {
    // D.2.1: a stored stripe_subscription_id that Stripe reports as
    // resource_missing is an INVESTIGATION condition, never an automatic
    // cancellation instruction. Do NOT synthesize status='canceled', do NOT
    // call the RPC, leave local lifecycle state unchanged. (0-subscription
    // discovery via the customer-list path above still returns the safe
    // no_subscription result and mutates nothing.)
    if (canon.kind === "transient") return { ok: false, code: "canonical_retrieve_transient" };
    return { ok: false, code: "canonical_subscription_missing" };
  } else {
    const sub = canon.subscription;
    // Identity corroboration against the stored mapping (never resolves).
    const storedCust = row.stripe_customer_id;
    const seenCust = stripeIdOf(sub.customer);
    const secondary =
      storedCust && seenCust && storedCust !== seenCust ? "customer_mismatch_seen_on_reconcile" : null;

    const price = extractCanonicalPrice(sub);
    if (!price.ok) {
      // Multi-item / no recurring price -- let the RPC fail closed via
      // unknown_price by passing the stored id (or null).
      args = {
        p_stripe_event_id: null,
        p_claim_token: null,
        p_organization_subscription_id: row.id,
        p_mode: "reconcile",
        p_stripe_customer_id: seenCust,
        p_stripe_subscription_id: sub.id,
        p_stripe_checkout_session_id: null,
        p_stripe_price_id: row.stripe_price_id,
        p_price_interval: null,
        p_status: typeof sub.status === "string" ? sub.status : "canceled",
        p_trial_end: unixToIso(sub.trial_end),
        p_current_period_start: currentPeriod(sub).start,
        p_current_period_end: currentPeriod(sub).end,
        p_cancel_at_period_end: sub.cancel_at_period_end === true,
        p_canceled_at: unixToIso(sub.canceled_at),
        p_event_at: null,
        p_secondary_conflict: secondary,
        p_invoice: null,
      };
    } else {
      args = buildApplyArgsFromSubscription({
        mode: "reconcile",
        eventId: null,
        claimToken: null,
        rowId: row.id,
        sub,
        priceId: price.priceId,
        priceInterval: price.interval,
        checkoutSessionId: null,
        eventAt: null,
        secondaryConflict: secondary,
        invoice: null,
      });
    }
  }

  const r = await callApplyStripeSubscriptionState(deps.db, args);
  if (!r.ok) return { ok: false, code: "rpc_exception", detail: r.detail };
  if (r.result === "reconciliation_required" || r.result === "reconciliation_required_billing_recorded") {
    return { ok: false, code: "reconciliation_required" };
  }
  return { ok: true, code: "reconciled", result: r.result };
}

// ---------------------------------------------------------------------------
// tiny local utilities
// ---------------------------------------------------------------------------
function readMetaOrgId(obj: Record<string, unknown>): string | null {
  const md = obj.metadata;
  if (md && typeof md === "object" && "organization_id" in md) {
    const v = (md as Record<string, unknown>).organization_id;
    return typeof v === "string" && v.length > 0 ? v : null;
  }
  return null;
}
function numOr(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}
