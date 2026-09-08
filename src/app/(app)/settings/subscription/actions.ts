"use server";

import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentOrgId } from "@/lib/actions/records";
import { createSubscriptionCheckout, type StartCheckoutResult } from "@/lib/stripe/checkout";
import { getStripe } from "@/lib/stripe/server";
import {
  reconcileOrganizationSubscription,
  type ReconcileRow,
  type StripeSyncApi,
  type StripeSyncDb,
} from "@/lib/stripe/subscription-state";

// PHASE C -- the ONLY browser-reachable entry point into Stripe SaaS
// checkout. It is the tenant-authorization boundary: organization identity
// comes from the authenticated server session (getCurrentOrgId), never
// from the argument. The browser may pass ONLY { tier, billing_cycle };
// everything else (Price, amount, currency, trial length, Customer id,
// success authority) is server-controlled downstream.
//
// Mirrors the app's existing integration-management pattern
// (settings/integrations/actions.ts): RLS is the unconditional backstop,
// plus an explicit app-level owner/admin check here so a non-admin gets a
// clear result instead of a confusing RLS no-op.
//
// Returns a plain result object (repo convention -- see
// carrier-onboarding/actions.ts). On success the caller redirects the
// browser to `url`. The success redirect grants nothing.

export type StartSubscriptionCheckoutInput = {
  tier: string;
  billing_cycle: string;
};

export async function startSubscriptionCheckout(
  input: StartSubscriptionCheckoutInput
): Promise<StartCheckoutResult> {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    return { ok: false, code: "not_authenticated", message: "Please sign in to manage billing." };
  }

  const { data: allowed } = await supabase.rpc("has_role", { p_roles: ["owner", "admin"] });
  if (!allowed) {
    return { ok: false, code: "forbidden", message: "Only an owner or admin can manage billing." };
  }

  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return { ok: false, code: "org_not_found", message: "No organization is associated with your account." };
  }

  const tier = typeof input?.tier === "string" ? input.tier.trim().toLowerCase() : "";
  const billingCycle =
    typeof input?.billing_cycle === "string" ? input.billing_cycle.trim().toLowerCase() : "";

  return createSubscriptionCheckout({
    organizationId,
    actorUserId: user.id,
    tier,
    billingCycle,
  });
}


export type CustomerPortalResult =
  | { ok: true; url: string }
  | { ok: false; message: string };

export async function createStripeCustomerPortalSession(): Promise<CustomerPortalResult> {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, message: "Please sign in to manage billing." };

  const { data: allowed } = await supabase.rpc("has_role", { p_roles: ["owner", "admin"] });
  if (!allowed) {
    return { ok: false, message: "Only an owner or admin can manage billing." };
  }

  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return { ok: false, message: "No organization is associated with your account." };
  }

  const service = createServiceRoleClient();
  const { data: subscription, error } = await service
    .from("organization_subscriptions")
    .select("stripe_customer_id, grandfathered_at")
    .eq("organization_id", organizationId)
    .maybeSingle();

  if (error) {
    console.error("[stripe-portal] subscription read failed:", error.message);
    return { ok: false, message: "Could not open billing management. Please try again." };
  }

  const row = subscription as {
    stripe_customer_id: string | null;
    grandfathered_at: string | null;
  } | null;

  if (!row?.stripe_customer_id || row.grandfathered_at !== null) {
    return { ok: false, message: "This organization is not connected to Stripe billing." };
  }

  const rawSiteUrl = (process.env.NEXT_PUBLIC_SITE_URL ?? "").trim();
  let returnUrl: string;
  try {
    const parsed = new URL(rawSiteUrl || "http://localhost:3000");
    if (
      process.env.NODE_ENV === "production" &&
      (parsed.protocol !== "https:" ||
        parsed.hostname === "localhost" ||
        parsed.hostname === "127.0.0.1")
    ) {
      throw new Error("invalid production URL");
    }
    returnUrl = new URL("/settings/subscription", parsed).toString();
  } catch {
    console.error("[stripe-portal] NEXT_PUBLIC_SITE_URL is invalid");
    return { ok: false, message: "Billing management is temporarily unavailable." };
  }

  try {
    const session = await getStripe().billingPortal.sessions.create({
      customer: row.stripe_customer_id,
      return_url: returnUrl,
    });
    return { ok: true, url: session.url };
  } catch (error) {
    console.error("[stripe-portal] session creation failed", {
      name: error instanceof Error ? error.name : "unknown",
    });
    return { ok: false, message: "Could not open billing management. Please try again." };
  }
}

// ---------------------------------------------------------------------------
// PHASE D.2 -- explicit, owner/admin-triggered reconciliation for the
// caller's OWN organization. Uses the SAME canonical normalization pipeline
// as the webhook (src/lib/stripe/subscription-state.ts) and calls the live
// 0127 RPC with p_mode='reconcile' (p_stripe_event_id / p_claim_token
// NULL). NEVER trusts a browser-supplied lifecycle field, org id, plan, or
// cycle -- organization identity comes from the authenticated session, and
// plan/cycle are derived in PostgreSQL from the canonical Stripe Price.
// Creates NO Stripe Customer / Checkout Session / Subscription. Not wired to
// any auto-trigger -- it runs only when a person explicitly invokes it.
// ---------------------------------------------------------------------------
export type ReconcileSubscriptionResult =
  | { ok: true; code: "reconciled" | "no_subscription" | "up_to_date"; message: string }
  | { ok: false; code: string; message: string };

export async function requestSubscriptionReconciliation(): Promise<ReconcileSubscriptionResult> {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    return { ok: false, code: "not_authenticated", message: "Please sign in to manage billing." };
  }

  const { data: allowed } = await supabase.rpc("has_role", { p_roles: ["owner", "admin"] });
  if (!allowed) {
    return { ok: false, code: "forbidden", message: "Only an owner or admin can manage billing." };
  }

  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return { ok: false, code: "org_not_found", message: "No organization is associated with your account." };
  }

  const service = createServiceRoleClient();
  const { data: sub, error: subErr } = await service
    .from("organization_subscriptions")
    .select(
      "id, organization_id, grandfathered_at, stripe_customer_id, stripe_subscription_id, stripe_price_id, organizations(billing_required)"
    )
    .eq("organization_id", organizationId)
    .maybeSingle();

  if (subErr) {
    console.error("[stripe-reconcile] subscription row read failed:", subErr.message);
    return { ok: false, code: "db_error", message: "Could not read billing state. Please try again." };
  }
  if (!sub) {
    return { ok: false, code: "not_found", message: "This organization has no billing record to reconcile yet." };
  }

  const row = sub as unknown as {
    id: string;
    organization_id: string;
    grandfathered_at: string | null;
    stripe_customer_id: string | null;
    stripe_subscription_id: string | null;
    stripe_price_id: string | null;
    organizations: { billing_required: boolean } | { billing_required: boolean }[] | null;
  };
  const orgRel = Array.isArray(row.organizations) ? row.organizations[0] : row.organizations;
  const reconcileRow: ReconcileRow = {
    id: row.id,
    organization_id: row.organization_id,
    grandfathered_at: row.grandfathered_at,
    stripe_customer_id: row.stripe_customer_id,
    stripe_subscription_id: row.stripe_subscription_id,
    stripe_price_id: row.stripe_price_id,
    billing_required: orgRel?.billing_required === true,
  };

  let stripe: ReturnType<typeof getStripe>;
  try {
    stripe = getStripe();
  } catch {
    return { ok: false, code: "stripe_not_configured", message: "Billing is temporarily unavailable. Please try again later." };
  }

  const result = await reconcileOrganizationSubscription(
    { stripe: stripe as unknown as StripeSyncApi, db: service as unknown as StripeSyncDb },
    { row: reconcileRow }
  );

  if (result.ok) {
    if (result.code === "no_subscription") {
      return { ok: true, code: "no_subscription", message: "No active Stripe subscription was found for this organization." };
    }
    return {
      ok: true,
      code: result.result === "stale_skipped" || result.result === "stale_skipped_billing_recorded" ? "up_to_date" : "reconciled",
      message: "Billing state has been reconciled with Stripe.",
    };
  }

  const messages: Record<string, string> = {
    grandfathered: "This organization has legacy billing access and does not use Stripe billing.",
    billing_not_required: "This organization is not on Stripe billing.",
    no_mapping: "This organization is not linked to Stripe yet -- start a checkout first.",
    multiple_subscriptions: "This organization has more than one Stripe subscription and needs manual review.",
    canonical_retrieve_transient: "Could not reach Stripe just now. Please try again in a moment.",
    canonical_subscription_missing:
      "Stripe no longer has the subscription this organization is linked to. This needs administrator review -- it is not treated as an automatic cancellation.",
    identity_conflict: "This organization's Stripe billing needs administrator review before it can be reconciled.",
    reconciliation_required: "Reconciliation found a conflict that needs administrator review. Please contact support.",
    rpc_exception: "Could not reconcile billing state. Please try again.",
    db_error: "Could not read billing state. Please try again.",
    not_found: "This organization has no billing record to reconcile yet.",
  };
  return { ok: false, code: result.code, message: messages[result.code] ?? "Could not reconcile billing state." };
}
