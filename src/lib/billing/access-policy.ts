// PHASE D.2.10 -- the ONE authoritative SaaS billing access-policy resolver.
//
// Every place that decides "may this authenticated org user enter the main
// TDP application, or only the billing/setup surface?" MUST go through
// resolveBillingAccess(). It is pure (no Supabase, no Stripe, no clock of
// its own -- `now` is passed in) so the whole policy is unit-testable and
// there is exactly one copy of it.
//
// This replaces the old crude middleware `BLOCKED_SUBSCRIPTION_STATUSES`
// deny-list, whose omissions (incomplete_expired, unpaid, unknown status,
// billing_required + no row) silently granted full access.
//
// Concept split (migration 0121):
//   organizations.billing_required              -- org-level. false = a
//     legacy/pre-billing org exempt from Stripe billing entirely.
//   organization_subscriptions.grandfathered_at -- subscription-level. A
//     permanent entitlement that needs no Stripe customer/card/checkout.
//
// Precedence (documented, tested):
//   1. billing_required === false      -> ALWAYS full access (exempt).
//   2. grandfathered_at IS NOT NULL    -> full access (permanent entitlement).
//   3. billing_required === true + NO subscription row -> FAIL CLOSED.
//   4. explicit per-status matrix; full access is an ALLOWLIST.
//   5. anything unrecognized / null    -> FAIL CLOSED (billing_only).

export type BillingAccess = "full" | "billing_only";

export type BillingAccessReason =
  | "billing_not_required"
  | "grandfathered"
  | "no_subscription"
  | "status_active"
  | "status_trialing"
  | "past_due_grace"
  | "past_due_grace_expired"
  | "past_due_no_anchor"
  | "status_incomplete"
  | "status_incomplete_expired"
  | "status_unpaid"
  | "status_paused"
  | "status_canceled"
  | "status_unknown";

export interface BillingAccessResult {
  access: BillingAccess;
  reason: BillingAccessReason;
}

// Minimum normalized facts the resolver needs. Callers extract these from
// their own rows -- the resolver never sees a Supabase row, an org id, a
// Stripe id, or anything sensitive.
export interface BillingFacts {
  /** organizations.billing_required (org-level authority). */
  billingRequired: boolean;
  /** Whether an organization_subscriptions row exists for the org. */
  subscriptionExists: boolean;
  /** organization_subscriptions.grandfathered_at (ISO string) or null. */
  grandfatheredAt: string | null;
  /** organization_subscriptions.status or null. */
  status: string | null;
  /** organization_subscriptions.past_due_since (ISO string) or null. */
  pastDueSince: string | null;
  /** Evaluation time. Passed in so the policy is deterministic + testable. */
  now: Date;
}

/** Product policy: a past_due subscription keeps full access for 7 days. */
export const PAST_DUE_GRACE_DAYS = 7;
export const PAST_DUE_GRACE_MS = PAST_DUE_GRACE_DAYS * 24 * 60 * 60 * 1000;

// Statuses that grant full app access for a billing-required,
// non-grandfathered org. This is an ALLOWLIST: a status not here (and not
// `past_due`, handled separately) resolves to billing_only. Add a status
// here ONLY with a deliberate product decision.
const FULL_ACCESS_STATUSES: ReadonlySet<string> = new Set(["active", "trialing"]);

// Known billing_only statuses -> their stable reason code. Kept explicit so
// an unrecognized/renamed status is visibly distinct (`status_unknown`) and
// still fails closed.
const BILLING_ONLY_REASON: Readonly<Record<string, BillingAccessReason>> = {
  incomplete: "status_incomplete",
  incomplete_expired: "status_incomplete_expired",
  unpaid: "status_unpaid",
  paused: "status_paused",
  canceled: "status_canceled",
};

function parseTimestampMs(iso: string | null): number | null {
  if (typeof iso !== "string" || iso.trim() === "") return null;
  const t = Date.parse(iso);
  return Number.isFinite(t) ? t : null;
}

export function resolveBillingAccess(facts: BillingFacts): BillingAccessResult {
  // 1. Not a Stripe-billed org -> never gated (0121: legacy/pre-billing
  //    organizations explicitly marked billing_required = false).
  if (facts.billingRequired !== true) {
    return { access: "full", reason: "billing_not_required" };
  }

  // 2. Grandfathered subscription -> full access, regardless of Stripe
  //    customer/subscription/price/trial fields. Wins over subscription
  //    status (a grandfathered row with status 'canceled' still gets in).
  if (facts.subscriptionExists && facts.grandfatheredAt !== null) {
    return { access: "full", reason: "grandfathered" };
  }

  // 3. billing_required + NO subscription row -> FAIL CLOSED. This is a new
  //    self-service org before checkout; it belongs on /settings/subscription.
  if (!facts.subscriptionExists) {
    return { access: "billing_only", reason: "no_subscription" };
  }

  // 4. Explicit status matrix. Full access is an ALLOWLIST.
  const status = facts.status;

  if (status !== null && FULL_ACCESS_STATUSES.has(status)) {
    return {
      access: "full",
      reason: status === "active" ? "status_active" : "status_trialing",
    };
  }

  if (status === "past_due") {
    // 7-day grace measured from organization_subscriptions.past_due_since.
    // No new timestamp column; the signed Stripe reconciliation path owns
    // this value. A missing/invalid anchor fails closed -- we never treat
    // `now` as the start of grace.
    const anchorMs = parseTimestampMs(facts.pastDueSince);
    if (anchorMs === null) {
      return { access: "billing_only", reason: "past_due_no_anchor" };
    }
    const graceEndsMs = anchorMs + PAST_DUE_GRACE_MS;
    // Boundary: strictly before grace end = full; AT or after = billing_only.
    if (facts.now.getTime() < graceEndsMs) {
      return { access: "full", reason: "past_due_grace" };
    }
    return { access: "billing_only", reason: "past_due_grace_expired" };
  }

  if (status !== null && status in BILLING_ONLY_REASON) {
    return { access: "billing_only", reason: BILLING_ONLY_REASON[status] };
  }

  // 5. Anything else -- null, "", an unrecognized/renamed Stripe status --
  //    FAILS CLOSED.
  return { access: "billing_only", reason: "status_unknown" };
}
