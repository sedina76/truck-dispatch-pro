import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { StatusBadge } from "@/components/ui/status-badge";
import { CheckoutCta } from "./checkout-cta";
import {
  checkoutReturnNotice,
  evaluateCheckoutGate,
  formatUsd,
  toSellablePlanCards,
  type PlanCardModel,
} from "./billing-view";
import { resolveBillingAccess } from "@/lib/billing/access-policy";

// PHASE D.2.8 -- production self-service billing entry point.
//
// Plan selection for a billing-required, non-grandfathered organization goes
// through the audited Stripe Checkout flow (CheckoutCta -> the
// startSubscriptionCheckout server action -> src/lib/stripe/checkout.ts).
// This page never mutates subscription state; the legacy local changePlan()
// path is gone from the billing flow (it now refuses anything but a
// grandfathered org). Stripe + signed webhooks + the 0127 RPC remain the
// sole authority for status / stripe_subscription_id / period / trial
// fields.

export default async function SubscriptionSettingsPage({
  searchParams,
}: {
  searchParams: Promise<{ checkout?: string }>;
}) {
  const { checkout } = await searchParams;
  const supabase = await createClient();
  const orgId = await getCurrentOrgId();

  const [{ data: allowed }, { data: subscription }, { data: org }, { data: plans }, { count: userCount }, { count: truckCount }, { count: activeLoadCount }] =
    await Promise.all([
      supabase.rpc("has_role", { p_roles: ["owner", "admin"] }),
      supabase
        .from("organization_subscriptions")
        .select("*, subscription_plans(*)")
        .eq("organization_id", orgId)
        .maybeSingle(),
      supabase.from("organizations").select("billing_required").eq("id", orgId).maybeSingle(),
      supabase.from("subscription_plans").select("*").eq("is_active", true).eq("is_public", true).order("monthly_price_cents"),
      supabase.from("profiles").select("id", { count: "exact", head: true }),
      supabase.from("trucks").select("id", { count: "exact", head: true }),
      supabase
        .from("loads")
        .select("id", { count: "exact", head: true })
        .in("status", ["booked", "dispatched", "in_transit", "at_pickup", "at_delivery"]),
    ]);

  const isOwnerOrAdmin = allowed === true;
  const sub = subscription as
    | (Record<string, unknown> & {
        status: string;
        grandfathered_at: string | null;
        past_due_since: string | null;
        subscription_plans: { id: string; name: string; tier: string } | null;
      })
    | null;
  const currentPlan = sub?.subscription_plans ?? null;
  const status = sub?.status ?? null;
  const grandfatheredAt = sub?.grandfathered_at ?? null;
  const billingRequired = (org as { billing_required: boolean } | null)?.billing_required ?? true;

  const gate = evaluateCheckoutGate({
    billingRequired,
    grandfatheredAt,
    status,
    isOwnerOrAdmin,
  });
  const planCards = toSellablePlanCards(plans ?? []);
  const returnNotice = checkoutReturnNotice(checkout, status);

  // Same authoritative resolver the middleware uses -- the "access is paused"
  // banner must never disagree with the redirect that landed the user here.
  const billingAccess = resolveBillingAccess({
    billingRequired,
    subscriptionExists: sub !== null,
    grandfatheredAt,
    status,
    pastDueSince: sub?.past_due_since ?? null,
    now: new Date(),
  });
  const isBlocked = billingAccess.access === "billing_only";
  const noticeToneClass: Record<string, string> = {
    positive: "border-success/30 bg-success/10 text-success",
    info: "border-[var(--color-brand)]/30 bg-[var(--color-brand)]/10 text-[var(--color-text)]",
    neutral: "border-[var(--color-border)] bg-[var(--color-surface)] text-[var(--color-text-muted)]",
  };

  return (
    <div className="space-y-6">
      <PageHeader title="Subscription & Billing" description="Plan, usage limits, and billing history." />

      {returnNotice && (
        <div className={"rounded-lg border p-4 text-sm " + noticeToneClass[returnNotice.tone]}>
          <p className="font-medium">{returnNotice.title}</p>
          <p className="mt-1 opacity-90">{returnNotice.body}</p>
        </div>
      )}

      {isBlocked && !returnNotice && (
        <div className="rounded-lg border border-danger/30 bg-danger/10 p-4 text-sm text-danger">
          <p className="font-medium">Access to the rest of the app is paused.</p>
          <p className="mt-1 text-danger/90">
            Your subscription status is{" "}
            <span className="font-medium">{status ? status.replace(/_/g, " ") : "not started"}</span>.{" "}
            {gate.canCheckout
              ? "Start your subscription below to restore access."
              : "Contact your account owner or support to restore access."}
          </p>
        </div>
      )}

      <div className="rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] p-4">
        <div className="flex items-center justify-between">
          <div>
            <p className="text-sm font-medium">Current plan</p>
            <p className="mt-1 text-2xl font-semibold">{currentPlan?.name ?? "No active plan"}</p>
            {grandfatheredAt !== null && (
              <p className="mt-1 text-xs text-[var(--color-text-muted)]">
                Legacy billing access &mdash; this organization is not billed through Stripe.
              </p>
            )}
          </div>
          {sub && <StatusBadge status={sub.status} />}
        </div>

        <div className="mt-4 grid grid-cols-3 gap-4 border-t border-[var(--color-border)] pt-4 text-sm">
          <div>
            <p className="text-[var(--color-text-muted)]">Users</p>
            <p className="font-medium">{userCount ?? 0}</p>
          </div>
          <div>
            <p className="text-[var(--color-text-muted)]">Trucks</p>
            <p className="font-medium">{truckCount ?? 0}</p>
          </div>
          <div>
            <p className="text-[var(--color-text-muted)]">Active Loads</p>
            <p className="font-medium">{activeLoadCount ?? 0}</p>
          </div>
        </div>
      </div>

      {gate.canCheckout && planCards.length > 0 ? (
        <div className="rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] p-4">
          <CheckoutCta plans={planCards} />
        </div>
      ) : (
        <PlanList
          plans={planCards}
          currentTier={currentPlan?.tier ?? null}
          note={gateNote(gate.reason, isOwnerOrAdmin)}
        />
      )}
    </div>
  );
}

function gateNote(
  reason: ReturnType<typeof evaluateCheckoutGate>["reason"],
  isOwnerOrAdmin: boolean
): string | null {
  switch (reason) {
    case "not_authorized":
      return "Only an owner or admin can start or change a subscription.";
    case "grandfathered":
      return "This organization has legacy billing access and is not billed through Stripe.";
    case "billing_not_required":
      return "This organization does not require a Stripe subscription.";
    case "existing_subscription":
      return isOwnerOrAdmin
        ? "Your subscription is managed through Stripe. Contact support to change plans."
        : null;
    default:
      return null;
  }
}

// Read-only reference list of active plans -- shown when a self-service
// Checkout CTA is not applicable (grandfathered, already subscribed,
// non-admin, or billing not required). No plan-change action is wired here.
function PlanList({
  plans,
  currentTier,
  note,
}: {
  plans: PlanCardModel[];
  currentTier: string | null;
  note: string | null;
}) {
  return (
    <div>
      <p className="mb-3 text-sm font-medium">Available plans</p>
      {note && <p className="mb-3 text-sm text-[var(--color-text-muted)]">{note}</p>}
      <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
        {plans.map((plan) => {
          const isCurrent = plan.tier === currentTier;
          return (
            <div
              key={plan.tier}
              className={
                "rounded-lg border p-4 " +
                (isCurrent ? "border-[var(--color-brand)]" : "border-[var(--color-border)]")
              }
            >
              <p className="font-medium">{plan.name}</p>
              <p className="mt-1 text-2xl font-semibold">
                {formatUsd(plan.monthlyCents)}
                <span className="text-sm font-normal text-[var(--color-text-muted)]">/mo</span>
              </p>
              <p className="mt-1 text-sm text-[var(--color-text-muted)]">
                or {formatUsd(plan.annualCents)}/year
              </p>
              {plan.description && (
                <p className="mt-2 text-sm text-[var(--color-text-muted)]">{plan.description}</p>
              )}
              {plan.features.length > 0 && (
                <ul className="mt-3 space-y-1 text-sm">
                  {plan.features.map((f) => (
                    <li key={String(f)}>&bull; {String(f)}</li>
                  ))}
                </ul>
              )}
              {isCurrent && (
                <div className="mt-4">
                  <StatusBadge status="active" />
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
