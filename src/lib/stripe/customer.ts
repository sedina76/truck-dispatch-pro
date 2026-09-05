import "server-only";
import type Stripe from "stripe";
import { getStripe } from "@/lib/stripe/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";

// ONE durable Stripe Customer per organization, for Truck Dispatch Pro's
// own SaaS subscription billing.
//
// Authoritative durable mapping: organization_subscriptions.stripe_customer_id
// (UNIQUE, service-role writes only -- there is no tenant INSERT/UPDATE
// policy on that table). This module never trusts a browser-supplied
// customer id and never derives tenant identity from email or name.
//
// Failure model this is built for:
//   1. Stripe Customer created successfully
//   2. process crashes before stripe_customer_id is persisted locally
//   3. a retry arrives
// A retry MUST NOT create an unbounded number of duplicate Customers.
// Two independent guards, each covering the other's blind spot:
//   * deterministic idempotency key `tdp_saas_customer_v1_<org>` -- within
//     the 24h Stripe retains the key, a repeat create returns the SAME
//     Customer even if the local mapping was never written and even if
//     Customer Search has not indexed it yet.
//   * exact metadata.organization_id search -- the durable recovery once
//     the 24h key window has passed. Never name/email matching.
// If more than one Customer claims the same organization_id, this STOPS
// and reports reconciliation-required rather than arbitrarily choosing one.

const CUSTOMER_IDEMPOTENCY_PREFIX = "tdp_saas_customer_v1_";

export type StripeCustomerResolutionCode = "reconciliation_required" | "stripe_error" | "persist_failed";

export type StripeCustomerResolution =
  | { ok: true; customerId: string; created: boolean }
  | { ok: false; code: StripeCustomerResolutionCode; message: string };

// Stable, generic, customer-safe copy per code. The caller
// (createSubscriptionCheckout) substitutes its own copy anyway; this is a
// safe default for any future direct caller. NEVER a raw Stripe/DB message.
const RESOLUTION_COPY: Record<StripeCustomerResolutionCode, string> = {
  reconciliation_required:
    "This organization's billing needs administrator attention before checkout can continue.",
  stripe_error: "Stripe could not be reached. Please try again in a moment.",
  persist_failed: "Could not finish billing setup for this organization. Please try again.",
};

function fail(code: StripeCustomerResolutionCode): StripeCustomerResolution {
  return { ok: false, code, message: RESOLUTION_COPY[code] };
}

// Server-side triage only. Never logs STRIPE_SECRET_KEY, Authorization
// headers, or a raw Stripe object -- only non-sensitive fields.
function logDiag(tag: string, err: unknown): void {
  const e = (err ?? {}) as { type?: unknown; code?: unknown; statusCode?: unknown; requestId?: unknown };
  const detail: Record<string, string> = {};
  if (typeof e.type === "string") detail.type = e.type;
  if (typeof e.code === "string") detail.code = e.code;
  if (typeof e.statusCode === "number") detail.statusCode = String(e.statusCode);
  if (typeof e.requestId === "string") detail.requestId = e.requestId;
  console.error(`[stripe-customer] ${tag}`, detail);
}

/**
 * Resolve (reuse, recover, or create) the single Stripe Customer for an
 * organization and make sure organization_subscriptions.stripe_customer_id
 * points at it.
 *
 * @param subscriptionRowId  the organization_subscriptions.id that the
 *   caller has already ensured exists (unique per org). The mapping is
 *   written onto THIS row.
 * @param existingCustomerId whatever stripe_customer_id currently holds
 *   for the org (may be null / blank).
 */
export async function resolveStripeCustomerForOrg(params: {
  organizationId: string;
  orgName: string;
  billingEmail: string | null;
  subscriptionRowId: string;
  existingCustomerId: string | null;
}): Promise<StripeCustomerResolution> {
  const { organizationId, orgName, billingEmail, subscriptionRowId, existingCustomerId } = params;

  // 1. Fast path -- a mapping is already stored. It was written by this
  //    function (or, later, by a signed webhook); trust it. Re-validating
  //    every checkout against Stripe would add a network round trip to the
  //    common case for no real safety gain.
  if (existingCustomerId && existingCustomerId.trim() !== "") {
    return { ok: true, customerId: existingCustomerId.trim(), created: false };
  }

  const stripe = getStripe();

  // 2. Recovery search -- mapping missing, but a Customer may already exist
  //    from an earlier attempt that crashed before persisting. Match ONLY
  //    on the immutable internal id in metadata.
  let matches: Stripe.Customer[];
  try {
    const search = await stripe.customers.search({
      query: `metadata['organization_id']:'${organizationId}'`,
      limit: 2,
    });
    matches = search.data;
  } catch (err) {
    logDiag("customer_search_failed", err);
    return fail("stripe_error");
  }

  if (matches.length > 1) {
    logDiag("multiple_customers_for_org", { code: organizationId });
    return fail("reconciliation_required");
  }

  let customerId: string;
  let created = false;

  if (matches.length === 1) {
    customerId = matches[0].id;
  } else {
    // 3. Create. Deterministic idempotency key scoped to org + purpose so a
    //    retry of the same logical "provision this org's customer"
    //    operation collapses to one Customer; distinct future operations
    //    (a different org, a different purpose prefix) are never collapsed.
    //    No timestamp / Date.now() in the key.
    try {
      const customer = await stripe.customers.create(
        {
          name: orgName,
          ...(billingEmail && billingEmail.trim() !== "" ? { email: billingEmail.trim() } : {}),
          // Immutable internal id only. No MC/DOT/EIN, no bank data, no
          // QuickBooks/load/driver/carrier data.
          metadata: {
            organization_id: organizationId,
            source: "tdp_saas_selfserve_checkout",
          },
        },
        { idempotencyKey: `${CUSTOMER_IDEMPOTENCY_PREFIX}${organizationId}` }
      );
      customerId = customer.id;
      created = true;
    } catch (err) {
      logDiag("customer_create_failed", err);
      return fail("stripe_error");
    }
  }

  // 4. Persist the mapping with a conditional write: claim the slot only
  //    while it is still empty. If a concurrent request already filled it,
  //    adopt the stored value instead -- and because the create above uses
  //    a deterministic idempotency key, a concurrent create resolved to the
  //    SAME cus_..., so there is no orphaned Customer.
  const service = createServiceRoleClient();
  const { data: claimed, error: claimErr } = await service
    .from("organization_subscriptions")
    .update({ stripe_customer_id: customerId })
    .eq("id", subscriptionRowId)
    .is("stripe_customer_id", null)
    .select("stripe_customer_id")
    .maybeSingle();

  if (claimErr) {
    logDiag("customer_persist_failed", claimErr);
    return fail("persist_failed");
  }
  if (claimed && (claimed as { stripe_customer_id: string | null }).stripe_customer_id) {
    return { ok: true, customerId, created };
  }

  // 0 rows updated -> the slot was already filled. Read the winner.
  const { data: current, error: readErr } = await service
    .from("organization_subscriptions")
    .select("stripe_customer_id")
    .eq("id", subscriptionRowId)
    .maybeSingle();

  const stored = (current as { stripe_customer_id: string | null } | null)?.stripe_customer_id ?? null;
  if (readErr || !stored) {
    if (readErr) logDiag("customer_reread_failed", readErr);
    return fail("persist_failed");
  }
  if (stored !== customerId) {
    // A different id than the one we just resolved. With the deterministic
    // key this should not happen; if it does, a Customer was created out of
    // band. Do not pick one.
    logDiag("customer_mapping_conflict", { code: organizationId });
    return fail("reconciliation_required");
  }
  return { ok: true, customerId: stored, created: false };
}
