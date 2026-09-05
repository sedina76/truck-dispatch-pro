import "server-only";
import { randomUUID } from "node:crypto";
import type Stripe from "stripe";
import { getStripe } from "@/lib/stripe/server";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { resolveStripeCustomerForOrg } from "@/lib/stripe/customer";

// =============================================================================
// PHASE C (+ C.1 concurrency repair, + C.2 durable attempt identity).
//
// !!! RUNTIME DEPENDENCY: migration 0124_stripe_checkout_attempt_identity.sql
// !!! MUST be applied + verified BEFORE this module is invoked in any
// !!! environment. It reads / writes organization_subscriptions
// !!! .stripe_checkout_attempt_id, which does not exist until 0124. Nothing
// !!! imports this module yet (no plan UI); it is inert in the repo until a
// !!! later phase wires a caller AND 0124 is live.
// =============================================================================
//
// The secure server-side START of the Stripe SaaS purchase lifecycle, and
// nothing past it:
//   authenticated owner/admin -> pick internal tier + cycle -> server
//   validates org eligibility -> server resolves the approved Price from
//   the DB -> server obtains/reuses ONE Stripe Customer -> server claims a
//   DURABLE, IMMUTABLE Checkout attempt identity on the org row -> ONLY the
//   attempt's lease holder creates ONE hosted Checkout Session -> server
//   persists the Session id only while it still holds the lease -> caller
//   redirects the browser to Stripe.
//
// COLUMN ROLE CONTRACT on organization_subscriptions:
//   stripe_checkout_attempt_id  IMMUTABLE logical attempt identity (uuid, 0124).
//                               Set once per attempt; NEVER changed by a
//                               worker takeover / crash retry; used to
//                               derive the Stripe idempotency key. Replaced
//                               / cleared ONLY on definitive attempt death.
//   checkout_pending_since      MUTABLE short-lived worker LEASE timestamp
//                               (0119). Advanced on every (re)claim.
//   stripe_checkout_session_id  Stripe Session pointer once known (0123).
//   plan_id / billing_cycle     FROZEN pending commercial intent of the
//                               current attempt. Never entitlement.
//   status = 'incomplete'       non-entitling local provisioning state.
//
// This module NEVER:
//   * activates a subscription or grants TMS access
//   * writes status='active' / status='trialing'
//   * writes stripe_subscription_id / stripe_price_id / period columns /
//     trial_end / past_due_since / stripe_event_at
//   * trusts an organization id, price, amount, currency, or trial length
//     from the browser
//   * mints a new attempt id merely because a lease went stale
//   * clears any durable pointer on an AMBIGUOUS external read failure
// The Checkout success redirect grants NOTHING. Stripe-derived lifecycle
// state is established later by signed webhook processing (a future phase).

const TRIAL_PERIOD_DAYS = 14;

// --- Time windows -----------------------------------------------------------

// LEASE staleness. The window between "this worker claimed the lease" and
// "this worker persisted the Session id" is one Stripe round trip plus one
// DB write -- seconds normally, tens of seconds pathologically; a
// serverless invocation cannot outlive its platform timeout (~60s). A
// lease older than 3 minutes with NO Session id stored is an abandoned /
// crashed worker and may be taken over -- WITHOUT changing the attempt id.
const CLAIM_STALE_MS = 3 * 60 * 1000;

// Stripe retains idempotency keys for ~24h and Checkout Sessions expire
// after ~24h. If an attempt's lease has been stale for this long with no
// Session ever persisted, an idempotent replay of checkout.sessions.create
// is NO LONGER guaranteed -- re-issuing CREATE could mint a SECOND Session.
// Past this point we DO NOT auto-recreate; we require manual reconciliation
// (safe-blocking). Chosen well inside the 24h guarantee. This uses the
// lease timestamp as a conservative lower bound on abandonment; a genuine
// crash-then-retry within the day always recovers via idempotent replay
// long before this fires, and a lease actively being taken over keeps
// resetting, so only a truly orphaned attempt trips it.
const ATTEMPT_RECONCILE_AFTER_MS = 20 * 60 * 60 * 1000;

const CHECKOUT_IDEMPOTENCY_PREFIX = "tdp_saas_checkout_v3_";

// Navigation-only. The existing /settings/subscription page renders live
// DB status; it does not treat these query params as activation. No
// onboarding pages are created in this phase.
const SUCCESS_PATH = "/settings/subscription?checkout=complete&session_id={CHECKOUT_SESSION_ID}";
const CANCEL_PATH = "/settings/subscription?checkout=canceled";

export type CheckoutTier = "essential" | "pro";
export type CheckoutBillingCycle = "monthly" | "annual";

export type StartCheckoutRefusalCode =
  | "not_authenticated"
  | "forbidden"
  | "invalid_tier"
  | "invalid_billing_cycle"
  | "org_not_found"
  | "billing_not_required"
  | "grandfathered"
  | "existing_subscription"
  | "checkout_in_progress"
  | "checkout_reconciliation_required"
  | "plan_unavailable"
  | "price_not_configured"
  | "stripe_not_configured"
  | "reconciliation_required"
  | "stripe_error"
  | "persist_failed"
  | "internal_error";

export type StartCheckoutResult =
  | { ok: true; kind: "redirect"; url: string }
  | { ok: true; kind: "already_completed" }
  | { ok: false; code: StartCheckoutRefusalCode; message: string };

// Stable, generic, customer-safe copy. NEVER a raw Stripe/DB error message,
// never a request id, never internal detail. Operational diagnostics go to
// the server log via logDiag().
const REFUSAL_COPY: Record<StartCheckoutRefusalCode, string> = {
  not_authenticated: "Please sign in to manage billing.",
  forbidden: "Only an owner or admin can manage billing.",
  invalid_tier: "Choose the Essential or Pro plan.",
  invalid_billing_cycle: "Choose monthly or annual billing.",
  org_not_found: "No organization is associated with your account.",
  billing_not_required:
    "This organization has legacy billing access and does not require Stripe checkout.",
  grandfathered:
    "This organization has legacy billing access and does not require Stripe checkout.",
  existing_subscription:
    "This organization already has an active subscription. Manage it from billing settings.",
  checkout_in_progress:
    "A checkout is already in progress for this organization. Finish or cancel it before choosing a different plan.",
  checkout_reconciliation_required:
    "This organization has a checkout that needs manual review before it can continue. Please contact support.",
  plan_unavailable: "That plan is not available for self-service checkout.",
  price_not_configured:
    "That plan is not fully configured for checkout yet. Please contact support.",
  stripe_not_configured:
    "Checkout is temporarily unavailable. Please try again later or contact support.",
  reconciliation_required:
    "This organization's billing needs administrator attention before checkout can continue.",
  stripe_error: "Stripe could not start checkout. Please try again in a moment.",
  persist_failed: "Could not start checkout. Please try again.",
  internal_error: "Something went wrong starting checkout. Please try again.",
};

function refuse(code: StartCheckoutRefusalCode): StartCheckoutResult {
  return { ok: false, code, message: REFUSAL_COPY[code] };
}

const VALID_TIERS: ReadonlySet<string> = new Set<CheckoutTier>(["essential", "pro"]);
const VALID_CYCLES: ReadonlySet<string> = new Set<CheckoutBillingCycle>(["monthly", "annual"]);

// Which stored organization_subscriptions.status values BLOCK a new
// self-service checkout vs. allow one. Conservative: anything that implies
// a live or dunning Stripe subscription is managed elsewhere (Customer
// Portal, a later phase), never re-purchased here.
const STATUS_BLOCKS_NEW_CHECKOUT: ReadonlySet<string> = new Set([
  "active",
  "trialing",
  "past_due",
  "unpaid",
  "paused",
]);
const STATUS_ALLOWS_NEW_CHECKOUT: ReadonlySet<string> = new Set([
  "incomplete",
  "incomplete_expired",
  "canceled",
]);

// Stripe error types that mean "the request was rejected and NOTHING was
// created" -- safe to definitively terminate the attempt. Every other
// error (connection error, generic API error, timeout, rate limit) is
// AMBIGUOUS: the Session may exist, so the attempt id + lease are kept and
// a retry reproduces the SAME idempotency key.
const DEFINITIVE_STRIPE_ERROR_TYPES: ReadonlySet<string> = new Set([
  "StripeInvalidRequestError",
  "StripeAuthenticationError",
  "StripePermissionError",
  "StripeIdempotencyError",
]);

type SubscriptionRow = {
  id: string;
  status: string;
  grandfathered_at: string | null;
  stripe_customer_id: string | null;
  stripe_checkout_session_id: string | null;
  stripe_checkout_attempt_id: string | null;
  checkout_pending_since: string | null;
  plan_id: string | null;
  billing_cycle: string | null;
};

type OrgRow = {
  id: string;
  name: string;
  business_email: string | null;
  billing_required: boolean;
};

type PlanRow = {
  id: string;
  tier: string;
  is_public: boolean;
  is_active: boolean;
  stripe_price_id_monthly: string | null;
  stripe_price_id_annual: string | null;
};

type ServiceClient = ReturnType<typeof createServiceRoleClient>;

const ROW_COLUMNS =
  "id, status, grandfathered_at, stripe_customer_id, stripe_checkout_session_id, stripe_checkout_attempt_id, checkout_pending_since, plan_id, billing_cycle";

function isUsableProductionSiteUrl(value: string): boolean {
  if (!value.trim()) return false;
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return false;
  }
  const host = parsed.hostname.toLowerCase();
  return host !== "localhost" && host !== "127.0.0.1" && host !== "::1" && !host.startsWith("127.");
}

function siteBaseUrl(): string {
  const raw = process.env.NEXT_PUBLIC_SITE_URL ?? "";
  if (process.env.NODE_ENV === "production" && !isUsableProductionSiteUrl(raw)) {
    throw new Error(
      "NEXT_PUBLIC_SITE_URL is missing, malformed, or points at localhost. Set it to the real deployed site URL before starting Stripe checkout."
    );
  }
  return (raw || "http://localhost:3000").replace(/\/$/, "");
}

// Server-side operational diagnostics ONLY. Never called with, and never
// logs, STRIPE_SECRET_KEY, Authorization headers, or a raw Stripe object.
// From a Stripe-shaped error it keeps only non-sensitive triage fields.
function logDiag(tag: string, err: unknown): void {
  const e = (err ?? {}) as { type?: unknown; code?: unknown; statusCode?: unknown; requestId?: unknown };
  const detail: Record<string, string> = {};
  if (typeof e.type === "string") detail.type = e.type;
  if (typeof e.code === "string") detail.code = e.code;
  if (typeof e.statusCode === "number") detail.statusCode = String(e.statusCode);
  if (typeof e.requestId === "string") detail.requestId = e.requestId;
  console.error(`[stripe-checkout] ${tag}`, detail);
}

function isDefinitiveStripeError(err: unknown): boolean {
  const t = (err as { type?: unknown } | null)?.type;
  return typeof t === "string" && DEFINITIVE_STRIPE_ERROR_TYPES.has(t);
}

// The ONLY throw shape that positively proves a stored Checkout Session
// does not exist: Stripe's canonical missing-resource signal on a
// retrieve-by-id (invalid_request_error + code 'resource_missing', usually
// HTTP 404). Anything else -- any other 4xx, any 5xx, a timeout, a
// connection error, a rate limit -- is treated as AMBIGUOUS and never
// clears a durable pointer.
function isStripeResourceMissing(err: unknown): boolean {
  const e = (err ?? {}) as { type?: unknown; code?: unknown; statusCode?: unknown };
  const isInvalidRequest = e.type === "StripeInvalidRequestError";
  if (!isInvalidRequest) return false;
  return e.code === "resource_missing" || e.statusCode === 404;
}

function stripeIdOf(value: string | { id: string } | null): string | null {
  if (value === null) return null;
  return typeof value === "string" ? value : value.id;
}

function ageMs(iso: string | null): number | null {
  if (!iso) return null;
  const t = Date.parse(iso);
  return Number.isFinite(t) ? Date.now() - t : null;
}

async function readRow(service: ServiceClient, organizationId: string): Promise<SubscriptionRow | null> {
  const { data } = await service
    .from("organization_subscriptions")
    .select(ROW_COLUMNS)
    .eq("organization_id", organizationId)
    .maybeSingle();
  return (data as SubscriptionRow | null) ?? null;
}

async function readSellablePlanByTier(
  supabase: Awaited<ReturnType<typeof createClient>>,
  tier: string
): Promise<PlanRow | null> {
  const { data } = await supabase
    .from("subscription_plans")
    .select("id, tier, is_public, is_active, stripe_price_id_monthly, stripe_price_id_annual")
    .eq("tier", tier)
    .eq("is_public", true)
    .eq("is_active", true)
    .maybeSingle();
  return (data as PlanRow | null) ?? null;
}

async function readPlanById(
  supabase: Awaited<ReturnType<typeof createClient>>,
  planId: string
): Promise<PlanRow | null> {
  const { data } = await supabase
    .from("subscription_plans")
    .select("id, tier, is_public, is_active, stripe_price_id_monthly, stripe_price_id_annual")
    .eq("id", planId)
    .maybeSingle();
  return (data as PlanRow | null) ?? null;
}

function priceForCycle(plan: PlanRow, cycle: CheckoutBillingCycle): string | null {
  const raw = cycle === "annual" ? plan.stripe_price_id_annual : plan.stripe_price_id_monthly;
  return raw && raw.trim() !== "" ? raw.trim() : null;
}

/**
 * Ensure an organization_subscriptions row exists, WITHOUT implying
 * entitlement and WITHOUT staking any attempt or lease. A freshly created
 * row is status='incomplete' (explicit -- the column default is 'trialing')
 * with attempt id, lease, and Session pointer all NULL. INSERT timing is
 * never the claim.
 */
async function ensureRow(
  service: ServiceClient,
  organizationId: string,
  planId: string,
  billingCycle: CheckoutBillingCycle
): Promise<{ ok: true; row: SubscriptionRow } | { ok: false }> {
  const existing = await readRow(service, organizationId);
  if (existing) return { ok: true, row: existing };

  const { error } = await service.from("organization_subscriptions").insert({
    organization_id: organizationId,
    plan_id: planId,
    billing_cycle: billingCycle,
    status: "incomplete",
    checkout_pending_since: null,
    stripe_checkout_session_id: null,
    stripe_checkout_attempt_id: null,
  });
  // 23505 = a concurrent request inserted the (unique) row first; fine.
  if (error && error.code !== "23505") {
    logDiag("ensure_row_insert_failed", error);
    return { ok: false };
  }

  const row = await readRow(service, organizationId);
  if (!row) return { ok: false };
  return { ok: true, row };
}

type StoredSessionVerdict =
  | { kind: "reuse"; url: string }
  | { kind: "completed" }
  | { kind: "in_progress" } // open, but for a DIFFERENT frozen intent -- never touch it
  | { kind: "replace" } // POSITIVE dead evidence -- safe to definitively terminate
  | { kind: "ambiguous" }; // could not determine -- keep every pointer, do not create

async function evaluateStoredSession(
  stripe: Stripe,
  sessionId: string,
  customerId: string,
  intentMatchesFrozen: boolean
): Promise<StoredSessionVerdict> {
  let session: Stripe.Checkout.Session;
  try {
    session = await stripe.checkout.sessions.retrieve(sessionId);
  } catch (err) {
    logDiag("session_retrieve_failed", err);
    return isStripeResourceMissing(err) ? { kind: "replace" } : { kind: "ambiguous" };
  }

  if (session.status === "complete") return { kind: "completed" };
  if (session.status === "expired") return { kind: "replace" };

  if (session.status === "open") {
    if (session.expires_at * 1000 <= Date.now()) return { kind: "replace" }; // Stripe's own expiry says dead
    const urlOk = typeof session.url === "string" && session.url.length > 0;
    const customerOk = stripeIdOf(session.customer) === customerId;
    if (!urlOk || !customerOk) return { kind: "ambiguous" }; // weird, but not proof of death
    return intentMatchesFrozen ? { kind: "reuse", url: session.url as string } : { kind: "in_progress" };
  }

  // Unknown / null status -> do not touch anything.
  return { kind: "ambiguous" };
}

async function terminateAttempt(service: ServiceClient, rowId: string, sessionId: string): Promise<void> {
  // DEFINITIVE termination: clear the Session pointer, the attempt id, and
  // the lease, conditionally on that exact dead Session id.
  await service
    .from("organization_subscriptions")
    .update({
      stripe_checkout_session_id: null,
      stripe_checkout_attempt_id: null,
      checkout_pending_since: null,
    })
    .eq("id", rowId)
    .eq("stripe_checkout_session_id", sessionId);
}

async function releaseAttempt(service: ServiceClient, rowId: string, attemptId: string): Promise<void> {
  // Definitive create-rejection proved no Session exists -> clear the
  // attempt id + lease, conditionally on still owning that attempt with no
  // Session persisted.
  await service
    .from("organization_subscriptions")
    .update({ stripe_checkout_attempt_id: null, checkout_pending_since: null })
    .eq("id", rowId)
    .eq("stripe_checkout_attempt_id", attemptId)
    .is("stripe_checkout_session_id", null);
}

/**
 * Begin (or safely resume) a Stripe-hosted subscription Checkout for the
 * caller's organization. `organizationId` / `actorUserId` MUST come from
 * the authenticated server session -- never from request input.
 *
 * REQUIRES migration 0124 (organization_subscriptions.stripe_checkout_attempt_id).
 */
export async function createSubscriptionCheckout(input: {
  organizationId: string;
  actorUserId: string;
  tier: string;
  billingCycle: string;
}): Promise<StartCheckoutResult> {
  const { organizationId, actorUserId, tier, billingCycle } = input;

  // 1. Shape validation (defence in depth -- the action validates too).
  if (!VALID_TIERS.has(tier)) return refuse("invalid_tier");
  if (!VALID_CYCLES.has(billingCycle)) return refuse("invalid_billing_cycle");
  const requestedTier = tier as CheckoutTier;
  const requestedCycle = billingCycle as CheckoutBillingCycle;

  // 2. Stripe must be configured (sandbox-only -- getStripe() rejects live
  //    keys). Fail before any DB work.
  let stripe: Stripe;
  try {
    stripe = getStripe();
  } catch (err) {
    logDiag("stripe_not_configured", err);
    return refuse("stripe_not_configured");
  }

  let siteUrl: string;
  try {
    siteUrl = siteBaseUrl();
  } catch (err) {
    logDiag("site_url_invalid", err);
    return refuse("internal_error");
  }

  const supabase = await createClient(); // RLS-scoped: reads + activity log with actor context
  const service = createServiceRoleClient(); // organization_subscriptions writes only

  // 3. Organization + self-service eligibility.
  const { data: orgData, error: orgErr } = await supabase
    .from("organizations")
    .select("id, name, business_email, billing_required")
    .eq("id", organizationId)
    .maybeSingle();
  if (orgErr) {
    logDiag("org_read_failed", orgErr);
    return refuse("internal_error");
  }
  const org = orgData as OrgRow | null;
  if (!org) return refuse("org_not_found");
  if (org.billing_required === false) return refuse("billing_not_required");

  // 4. Existing subscription state (eligibility only).
  const preRow = await readRow(service, organizationId);
  if (preRow) {
    if (preRow.grandfathered_at !== null) return refuse("grandfathered");
    if (STATUS_BLOCKS_NEW_CHECKOUT.has(preRow.status)) return refuse("existing_subscription");
    if (!STATUS_ALLOWS_NEW_CHECKOUT.has(preRow.status)) {
      logDiag("unexpected_status", { code: preRow.status });
      return refuse("internal_error");
    }
  }

  // 5. Resolve the REQUESTED plan + Price from the DB. The browser never
  //    supplies a Price/Product id, amount, currency, or trial length.
  const requestedPlan = await readSellablePlanByTier(supabase, requestedTier);
  if (!requestedPlan) return refuse("plan_unavailable");
  const requestedPriceId = priceForCycle(requestedPlan, requestedCycle);
  if (!requestedPriceId) return refuse("price_not_configured");

  // 6. Ensure a subscription row (non-entitling, no attempt / lease staked).
  const ensured = await ensureRow(service, organizationId, requestedPlan.id, requestedCycle);
  if (!ensured.ok) return refuse("persist_failed");
  const rowId = ensured.row.id;

  // 7. One durable Stripe Customer for the org (idempotent; safe before the
  //    attempt claim -- a loser has merely reused the same cus_...).
  const customer = await resolveStripeCustomerForOrg({
    organizationId,
    orgName: org.name,
    billingEmail: org.business_email,
    subscriptionRowId: rowId,
    existingCustomerId: ensured.row.stripe_customer_id,
  });
  if (!customer.ok) {
    if (customer.code === "reconciliation_required") return refuse("reconciliation_required");
    logDiag("customer_resolve_failed", { code: customer.code });
    return refuse(customer.code === "stripe_error" ? "stripe_error" : "persist_failed");
  }
  const customerId = customer.customerId;
  if (customer.created) {
    await logSafe(supabase, organizationId, "stripe_customer_mapping_established", {
      tier: requestedTier,
      billing_cycle: requestedCycle,
      initiated_by: actorUserId,
    });
  }

  // 8. CLAIM (durable attempt id + short lease) + CREATE. At most one
  //    caller per organization may reach stripe.checkout.sessions.create
  //    while a fresh lease exists -- regardless of plan / cycle / Price /
  //    tab. Bounded to two passes so one dead-Session termination can be
  //    retried without an unbounded loop.
  for (let attempt = 0; attempt < 2; attempt++) {
    const cur = await readRow(service, organizationId);
    if (!cur) return refuse("persist_failed");

    const frozenIntentMatches =
      cur.plan_id === requestedPlan.id && cur.billing_cycle === requestedCycle;

    // 8a. A Session pointer already exists -> evaluate it; never claim / never
    //     create on top of it.
    if (cur.stripe_checkout_session_id) {
      const verdict = await evaluateStoredSession(
        stripe,
        cur.stripe_checkout_session_id,
        customerId,
        frozenIntentMatches
      );
      if (verdict.kind === "reuse") return { ok: true, kind: "redirect", url: verdict.url };
      if (verdict.kind === "completed") return { ok: true, kind: "already_completed" };
      if (verdict.kind === "in_progress") return refuse("checkout_in_progress");
      if (verdict.kind === "ambiguous") return refuse("stripe_error"); // keep every pointer
      // verdict.kind === "replace": POSITIVE dead evidence only.
      if (attempt === 0) {
        await terminateAttempt(service, cur.id, cur.stripe_checkout_session_id);
        continue; // re-read from a clean slate -> new attempt
      }
      return refuse("checkout_in_progress");
    }

    // 8b. No Session pointer, but an ATTEMPT is in flight.
    if (cur.stripe_checkout_attempt_id) {
      if (!frozenIntentMatches) return refuse("checkout_in_progress"); // never mutate the attempt

      const lease = cur.checkout_pending_since;
      const leaseAge = ageMs(lease);

      if (lease === null) {
        // Attempt id present but no lease: an inconsistent partial state we
        // never write. Do not guess -- require reconciliation (safe-block).
        logDiag("attempt_without_lease", { code: cur.id });
        return refuse("checkout_reconciliation_required");
      }
      if (leaseAge !== null && leaseAge < CLAIM_STALE_MS) {
        return refuse("checkout_in_progress"); // another worker owns the create window
      }
      if (leaseAge !== null && leaseAge >= ATTEMPT_RECONCILE_AFTER_MS) {
        // Idempotent replay is no longer guaranteed. Do NOT re-create.
        logDiag("attempt_past_reconcile_window", { code: cur.stripe_checkout_attempt_id });
        return refuse("checkout_reconciliation_required");
      }

      // Worker TAKEOVER: advance the lease ONLY. Attempt id stays A.
      const { data: took } = await service
        .from("organization_subscriptions")
        .update({ checkout_pending_since: new Date().toISOString() })
        .eq("id", cur.id)
        .eq("stripe_checkout_attempt_id", cur.stripe_checkout_attempt_id)
        .is("stripe_checkout_session_id", null)
        .eq("checkout_pending_since", lease)
        .select("checkout_pending_since, stripe_checkout_attempt_id")
        .maybeSingle();

      if (!took) {
        if (attempt === 0) continue; // lost the takeover race -> re-read
        return refuse("checkout_in_progress");
      }
      const claimed = took as { checkout_pending_since: string; stripe_checkout_attempt_id: string };
      return await createForClaim({
        stripe,
        service,
        supabase,
        siteUrl,
        organizationId,
        actorUserId,
        customerId,
        rowId: cur.id,
        attemptId: claimed.stripe_checkout_attempt_id,
        leaseToken: claimed.checkout_pending_since,
        frozenPlanId: cur.plan_id,
        frozenCycleRaw: cur.billing_cycle,
      });
    }

    // 8c. No Session, no attempt -> claim a brand-new attempt.
    const newAttemptId = randomUUID();
    const newLease = new Date().toISOString();
    const { data: staked } = await service
      .from("organization_subscriptions")
      .update({
        stripe_checkout_attempt_id: newAttemptId,
        checkout_pending_since: newLease,
        plan_id: requestedPlan.id,
        billing_cycle: requestedCycle,
      })
      .eq("id", cur.id)
      .is("stripe_checkout_session_id", null)
      .is("stripe_checkout_attempt_id", null)
      .is("checkout_pending_since", null)
      .select("stripe_checkout_attempt_id, checkout_pending_since")
      .maybeSingle();

    if (!staked) {
      if (attempt === 0) continue; // lost the claim race -> re-read (attempt now exists)
      return refuse("checkout_in_progress");
    }
    const s = staked as { stripe_checkout_attempt_id: string; checkout_pending_since: string };
    return await createForClaim({
      stripe,
      service,
      supabase,
      siteUrl,
      organizationId,
      actorUserId,
      customerId,
      rowId: cur.id,
      attemptId: s.stripe_checkout_attempt_id,
      leaseToken: s.checkout_pending_since,
      frozenPlanId: requestedPlan.id,
      frozenCycleRaw: requestedCycle,
    });
  }

  return refuse("checkout_in_progress");
}

/**
 * The claim winner's path: resolve the FROZEN attempt intent's Price, call
 * Stripe with the attempt-derived idempotency key, persist the Session id
 * only while still holding the lease.
 */
async function createForClaim(args: {
  stripe: Stripe;
  service: ServiceClient;
  supabase: Awaited<ReturnType<typeof createClient>>;
  siteUrl: string;
  organizationId: string;
  actorUserId: string;
  customerId: string;
  rowId: string;
  attemptId: string;
  leaseToken: string;
  frozenPlanId: string | null;
  frozenCycleRaw: string | null;
}): Promise<StartCheckoutResult> {
  const {
    stripe,
    service,
    supabase,
    siteUrl,
    organizationId,
    actorUserId,
    customerId,
    rowId,
    attemptId,
    leaseToken,
    frozenPlanId,
    frozenCycleRaw,
  } = args;

  if (!frozenPlanId || (frozenCycleRaw !== "monthly" && frozenCycleRaw !== "annual")) {
    logDiag("frozen_intent_unusable", { code: rowId });
    await releaseAttempt(service, rowId, attemptId);
    return refuse("internal_error");
  }
  const frozenCycle = frozenCycleRaw as CheckoutBillingCycle;

  // Re-resolve the FROZEN plan's Price from the DB. A retry / takeover of
  // this attempt therefore always sends identical Stripe parameters.
  const frozenPlan = await readPlanById(supabase, frozenPlanId);
  if (!frozenPlan || !frozenPlan.is_public || !frozenPlan.is_active) {
    // The plan this attempt froze is no longer sellable. Do not silently
    // switch plans and do not create -- a human decides.
    logDiag("frozen_plan_no_longer_sellable", { code: frozenPlanId });
    return refuse("checkout_reconciliation_required");
  }
  const frozenPriceId = priceForCycle(frozenPlan, frozenCycle);
  if (!frozenPriceId) {
    logDiag("frozen_price_missing", { code: frozenPlanId });
    return refuse("checkout_reconciliation_required");
  }

  // Idempotency key = immutable row id + IMMUTABLE attempt id. No Price, no
  // timestamp. Every retry / takeover of this attempt reproduces it exactly
  // and Stripe replays the same Session.
  const idempotencyKey = `${CHECKOUT_IDEMPOTENCY_PREFIX}${rowId}_${attemptId}`;

  const reconciliationMetadata = {
    organization_id: organizationId,
    plan_id: frozenPlanId,
    plan_tier: frozenPlan.tier,
    billing_cycle: frozenCycle,
    price_id: frozenPriceId,
    checkout_attempt_id: attemptId,
  };

  let session: Stripe.Checkout.Session;
  try {
    session = await stripe.checkout.sessions.create(
      {
        mode: "subscription",
        customer: customerId,
        line_items: [{ price: frozenPriceId, quantity: 1 }],
        payment_method_collection: "always",
        subscription_data: {
          trial_period_days: TRIAL_PERIOD_DAYS,
          trial_settings: { end_behavior: { missing_payment_method: "cancel" } },
          metadata: reconciliationMetadata,
        },
        client_reference_id: organizationId,
        metadata: reconciliationMetadata,
        success_url: `${siteUrl}${SUCCESS_PATH}`,
        cancel_url: `${siteUrl}${CANCEL_PATH}`,
      },
      { idempotencyKey }
    );
  } catch (err) {
    logDiag("session_create_failed", err);
    if (isDefinitiveStripeError(err)) {
      // Rejected; nothing created -> definitive attempt termination so the
      // org is not stuck behind a dead attempt.
      await releaseAttempt(service, rowId, attemptId);
    }
    // Otherwise AMBIGUOUS: keep the attempt id + lease so a retry
    // reproduces this exact key.
    return refuse("stripe_error");
  }

  if (session.status === "complete") return { ok: true, kind: "already_completed" };
  if (session.status !== "open" || !session.url) {
    logDiag("session_not_open", { code: session.id });
    return refuse("stripe_error"); // keep the attempt (ambiguous)
  }

  // Persist the Session id ONLY while still holding this exact lease on
  // this exact attempt.
  const { data: persisted } = await service
    .from("organization_subscriptions")
    .update({ stripe_checkout_session_id: session.id })
    .eq("id", rowId)
    .eq("stripe_checkout_attempt_id", attemptId)
    .eq("checkout_pending_since", leaseToken)
    .is("stripe_checkout_session_id", null)
    .select("id")
    .maybeSingle();

  if (!persisted) {
    // Lost the lease mid-call (a >3-minute-stale takeover by another
    // worker). The Session exists under the attempt-derived key; converge
    // on whatever the winning worker persisted.
    const after = await readRow(service, organizationId);
    if (after?.stripe_checkout_session_id) {
      const v = await evaluateStoredSession(stripe, after.stripe_checkout_session_id, customerId, true);
      if (v.kind === "reuse") return { ok: true, kind: "redirect", url: v.url };
      if (v.kind === "completed") return { ok: true, kind: "already_completed" };
    }
    return refuse("checkout_in_progress");
  }

  await logSafe(supabase, organizationId, "stripe_checkout_session_created", {
    tier: frozenPlan.tier,
    billing_cycle: frozenCycle,
    initiated_by: actorUserId,
  });
  return { ok: true, kind: "redirect", url: session.url };
}

async function logSafe(
  supabase: Awaited<ReturnType<typeof createClient>>,
  organizationId: string,
  action: string,
  changes: Record<string, string>
): Promise<void> {
  // Only safe identifiers/actions. Never secrets, never raw Stripe
  // objects. Never claims a subscription was activated. entity_type has no
  // 'subscription'/'billing' member -- the superadmin console logs
  // subscription changes as 'organization' too.
  try {
    await supabase.rpc("log_activity", {
      p_entity_type: "organization",
      p_entity_id: organizationId,
      p_action: action,
      p_changes: changes,
      p_organization_id: organizationId,
    });
  } catch {
    // Activity logging is best-effort and must never break checkout.
  }
}
