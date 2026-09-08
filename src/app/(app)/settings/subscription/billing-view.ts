// Pure, framework-free helpers for the /settings/subscription billing page.
// No React, no Supabase, no Stripe import -- so the eligibility rules and the
// user-facing copy are unit-testable under `node --test`. The page (server
// component) and the checkout CTA (client component) both import from here;
// neither re-derives these rules.
//
// PHASE D.2.8 -- production self-service Checkout entry point. This module
// decides ONLY whether to SHOW a "Start 30-Day Free Trial" CTA. The authoritative
// eligibility + concurrency + idempotency checks live server-side in
// src/lib/stripe/checkout.ts (createSubscriptionCheckout); the constants
// below intentionally MIRROR that module and must be kept in sync with it.

export type BillingCycle = "monthly" | "annual";

// The ONLY tiers self-service Checkout offers. Mirrors VALID_TIERS in
// src/lib/stripe/checkout.ts.
export const SELLABLE_TIERS = ["essential", "pro"] as const;
export type SellableTier = (typeof SELLABLE_TIERS)[number];

// Stored organization_subscriptions.status values that mean "a live or
// dunning Stripe subscription is managed elsewhere -- never start a NEW
// self-service Checkout". Mirrors STATUS_BLOCKS_NEW_CHECKOUT in
// src/lib/stripe/checkout.ts.
export const STATUS_BLOCKS_NEW_CHECKOUT: ReadonlySet<string> = new Set([
  "active",
  "trialing",
  "past_due",
  "unpaid",
  "paused",
]);

// Stored statuses from which a fresh self-service Checkout IS allowed.
// Mirrors STATUS_ALLOWS_NEW_CHECKOUT in src/lib/stripe/checkout.ts.
export const STATUS_ALLOWS_NEW_CHECKOUT: ReadonlySet<string> = new Set([
  "incomplete",
  "incomplete_expired",
  "canceled",
]);

export type CheckoutGateReason =
  | "eligible"
  | "no_subscription_row" // no row yet -> still eligible (checkout.ts ensureRow makes one)
  | "not_authorized"
  | "grandfathered"
  | "billing_not_required"
  | "existing_subscription"
  | "unknown_status";

/**
 * Decide whether the billing page should render a self-service Checkout CTA.
 *
 * `status === null` means the organization has no organization_subscriptions
 * row yet -- that is still eligible, because createSubscriptionCheckout()
 * creates a non-entitling row itself.
 *
 * Order note: `grandfathered` is reported before `billing_not_required` so a
 * legacy org gets the clearer message; both outcomes are `canCheckout:false`,
 * so the order never changes whether the CTA shows.
 */
export function evaluateCheckoutGate(input: {
  billingRequired: boolean;
  grandfatheredAt: string | null;
  status: string | null;
  isOwnerOrAdmin: boolean;
}): { canCheckout: boolean; reason: CheckoutGateReason } {
  if (!input.isOwnerOrAdmin) return { canCheckout: false, reason: "not_authorized" };
  if (input.grandfatheredAt !== null) return { canCheckout: false, reason: "grandfathered" };
  if (!input.billingRequired) return { canCheckout: false, reason: "billing_not_required" };
  if (input.status === null) return { canCheckout: true, reason: "no_subscription_row" };
  if (STATUS_BLOCKS_NEW_CHECKOUT.has(input.status)) {
    return { canCheckout: false, reason: "existing_subscription" };
  }
  if (STATUS_ALLOWS_NEW_CHECKOUT.has(input.status)) {
    return { canCheckout: true, reason: "eligible" };
  }
  return { canCheckout: false, reason: "unknown_status" };
}

export type CheckoutReturnNotice = {
  tone: "positive" | "neutral" | "info";
  title: string;
  body: string;
};

/**
 * Copy for the ?checkout=complete / ?checkout=canceled return states.
 *
 * The browser redirect from Stripe is NON-AUTHORITATIVE: on `complete` we
 * only claim the subscription is active when the live DB status already says
 * so (a signed webhook + the 0127 RPC established it). Otherwise we show a
 * "still confirming" message. `canceled` never implies any state change.
 */
export function checkoutReturnNotice(
  param: string | undefined,
  status: string | null
): CheckoutReturnNotice | null {
  if (param === "complete") {
    const activationConfirmed = status === "trialing" || status === "active";
    if (activationConfirmed) {
      return {
        tone: "positive",
        title: "Subscription confirmed.",
        body: "Your subscription is active. Thanks for choosing Truck Dispatch Pro.",
      };
    }
    return {
      tone: "info",
      title: "Checkout completed. We're confirming your subscription.",
      body: "Stripe is finishing up. This page refreshes on its own once your subscription is confirmed -- it usually takes only a moment.",
    };
  }
  if (param === "canceled") {
    return {
      tone: "neutral",
      title: "Checkout canceled.",
      body: "No changes were made to your subscription. You can start again whenever you're ready.",
    };
  }
  return null;
}

// Safe, generic client-side fallback copy per refusal code from
// startSubscriptionCheckout / createSubscriptionCheckout. The server action
// already returns a safe `message`; this is only a backstop so a raw
// Stripe/Supabase string can never surface if `message` is ever absent.
const REFUSAL_FALLBACK: Record<string, string> = {
  not_authenticated: "Please sign in to manage billing.",
  forbidden: "Only an owner or admin can manage billing.",
  org_not_found: "No organization is associated with your account.",
  invalid_tier: "Choose the Essential or Pro plan.",
  invalid_billing_cycle: "Choose monthly or annual billing.",
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

export function refusalMessage(code: string | undefined, message?: string | null): string {
  if (message && message.trim() !== "") return message;
  if (code && REFUSAL_FALLBACK[code]) return REFUSAL_FALLBACK[code];
  return "Something went wrong starting checkout. Please try again.";
}

export function formatUsd(cents: number): string {
  const dollars = cents / 100;
  return Number.isInteger(dollars)
    ? `$${dollars.toLocaleString("en-US")}`
    : `$${dollars.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

/** Per-month figure when billed annually, for the "$X/mo billed yearly" line. */
export function annualMonthlyEquivalent(annualCents: number): string {
  return formatUsd(Math.round(annualCents / 12));
}

export type PlanCardModel = {
  tier: SellableTier;
  name: string;
  monthlyCents: number;
  annualCents: number;
  description: string;
  features: string[];
};

/**
 * Shape raw subscription_plans rows into the client CTA's display model,
 * keeping only public + active sellable tiers, ordered Essential then Pro.
 * Stripe Price IDs are deliberately NOT included -- they never reach the
 * client; the server action + checkout.ts resolve them from the DB.
 */
export function toSellablePlanCards(
  rows: Array<{
    tier: string | null;
    name: string | null;
    monthly_price_cents: number | null;
    annual_price_cents: number | null;
    description: string | null;
    features: unknown;
    is_public: boolean | null;
    is_active: boolean | null;
  }>
): PlanCardModel[] {
  const order: Record<SellableTier, number> = { essential: 0, pro: 1 };
  return rows
    .filter(
      (r): r is typeof r & { tier: SellableTier } =>
        r.is_public === true &&
        r.is_active === true &&
        typeof r.tier === "string" &&
        (SELLABLE_TIERS as readonly string[]).includes(r.tier)
    )
    .map((r) => ({
      tier: r.tier,
      name: r.name ?? r.tier,
      monthlyCents: r.monthly_price_cents ?? 0,
      annualCents: r.annual_price_cents ?? 0,
      description: r.description ?? "",
      features: Array.isArray(r.features) ? (r.features as unknown[]).map(String) : [],
    }))
    .sort((a, b) => order[a.tier] - order[b.tier]);
}
