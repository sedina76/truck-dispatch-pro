import "server-only";
import { cache } from "react";
import { createClient } from "@/lib/supabase/server";
import { resolveBillingAccess } from "@/lib/billing/access-policy";

// PHASE D.2.11 -- server-side SaaS paywall for OPERATIONAL writes.
//
// D.2.10 gated page navigation in middleware. This closes the remaining
// same-organization bypass: a billing-lapsed tenant with a valid session
// could still POST a server action directly. Operational mutation
// chokepoints call requireOperationalAccess() (or checkOperationalAccess())
// BEFORE the business write.
//
// It does NOT re-implement policy: it gathers the same minimum facts the
// middleware gathers and defers to the ONE authority,
// resolveBillingAccess() (src/lib/billing/access-policy.ts). No status
// matrix, no 7-day arithmetic here.
//
// NOT for: billing-recovery actions (startSubscriptionCheckout,
// requestSubscriptionReconciliation), the signed Stripe webhook / its
// service-role RPCs, auth/sign-out, or reads. Those must stay reachable for
// a billing_only tenant so it can recover.

/** Stable, typed refusal. Distinct from unauthenticated / role-forbidden /
 *  tenant-mismatch / validation / not-found / db-failure. Never carries a
 *  raw Supabase or Stripe message. */
export class OperationalAccessError extends Error {
  readonly code:
    | "billing_access_required"
    | "billing_state_unavailable"
    | "not_authenticated"
    | "no_organization";
  /** resolveBillingAccess reason, or an internal marker. Safe to log. */
  readonly reason: string;

  constructor(
    code: OperationalAccessError["code"],
    reason: string,
    message = "Your organization's subscription does not permit this action."
  ) {
    super(message);
    this.name = "OperationalAccessError";
    this.code = code;
    this.reason = reason;
  }
}

export type OperationalAccessResult =
  | { ok: true; organizationId: string }
  | {
      ok: false;
      code: OperationalAccessError["code"];
      reason: string;
    };

// Request-scoped memoization: React cache() dedupes within a SINGLE server
// request, so several chokepoints in one server action resolve the billing
// facts once. It is NOT a cross-request or cross-user cache -- every request
// re-runs this.
const loadOperationalAccess = cache(async (): Promise<OperationalAccessResult> => {
  const supabase = await createClient();

  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();
  if (userError || !user) {
    return { ok: false, code: "not_authenticated", reason: "no_authenticated_user" };
  }

  // Trusted organization id: the authenticated user's own profile row.
  // Never an argument, header, or form field.
  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .select("organization_id")
    .eq("id", user.id)
    .maybeSingle();
  if (profileError) {
    // FAIL CLOSED -- cannot determine billing state.
    return { ok: false, code: "billing_state_unavailable", reason: "profile_read_failed" };
  }
  const organizationId = profile?.organization_id ?? null;
  if (!organizationId) {
    // A platform admin (no org) has no operational tenant surface to write
    // to; an unprovisioned user likewise. Deny operational writes.
    return { ok: false, code: "no_organization", reason: "no_organization" };
  }

  const [orgResult, subscriptionResult] = await Promise.all([
    supabase
      .from("organizations")
      .select("billing_required")
      .eq("id", organizationId)
      .maybeSingle(),
    supabase
      .from("organization_subscriptions")
      .select("status, grandfathered_at, past_due_since")
      .eq("organization_id", organizationId)
      .maybeSingle(),
  ]);

  if (orgResult.error || subscriptionResult.error) {
    // FAIL CLOSED -- a required billing-state read failed.
    return { ok: false, code: "billing_state_unavailable", reason: "billing_read_failed" };
  }

  const org = orgResult.data as { billing_required: boolean } | null;
  const subscription = subscriptionResult.data as {
    status: string | null;
    grandfathered_at: string | null;
    past_due_since: string | null;
  } | null;

  const decision = resolveBillingAccess({
    billingRequired: org?.billing_required === true,
    subscriptionExists: subscription !== null,
    grandfatheredAt: subscription?.grandfathered_at ?? null,
    status: subscription?.status ?? null,
    pastDueSince: subscription?.past_due_since ?? null,
    now: new Date(),
  });

  if (decision.access !== "full") {
    return { ok: false, code: "billing_access_required", reason: decision.reason };
  }
  return { ok: true, organizationId };
});

/**
 * Non-throwing check. Use in server actions that return a structured result
 * object rather than throwing.
 */
export function checkOperationalAccess(): Promise<OperationalAccessResult> {
  return loadOperationalAccess();
}

/**
 * Throwing guard for operational mutation chokepoints. Call BEFORE the
 * business write. Returns the trusted organization id on success; throws a
 * typed OperationalAccessError otherwise (fail-closed).
 */
export async function requireOperationalAccess(): Promise<{ organizationId: string }> {
  const result = await loadOperationalAccess();
  if (result.ok) return { organizationId: result.organizationId };
  throw new OperationalAccessError(result.code, result.reason);
}
