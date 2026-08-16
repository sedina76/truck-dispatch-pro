import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { StatusBadge } from "@/components/ui/status-badge";
import { Button } from "@/components/ui/button";
import { changePlan } from "../actions";

export default async function SubscriptionSettingsPage() {
  const supabase = await createClient();
  const orgId = await getCurrentOrgId();

  const [{ data: subscription }, { data: plans }, { count: userCount }, { count: truckCount }, { count: activeLoadCount }] =
    await Promise.all([
      supabase
        .from("organization_subscriptions")
        .select("*, subscription_plans(*)")
        .eq("organization_id", orgId)
        .maybeSingle(),
      supabase.from("subscription_plans").select("*").eq("is_active", true).order("monthly_price_cents"),
      supabase.from("profiles").select("id", { count: "exact", head: true }),
      supabase.from("trucks").select("id", { count: "exact", head: true }),
      supabase
        .from("loads")
        .select("id", { count: "exact", head: true })
        .in("status", ["booked", "dispatched", "in_transit", "at_pickup", "at_delivery"]),
    ]);

  const currentPlan = (subscription as unknown as { subscription_plans: { id: string; name: string } | null })
    ?.subscription_plans;

  const isBlocked = subscription && ["past_due", "paused", "canceled", "incomplete"].includes(subscription.status);

  return (
    <div className="space-y-6">
      <PageHeader title="Subscription & Billing" description="Plan, usage limits, and billing history." />

      {isBlocked && (
        <div className="rounded-lg border border-danger/30 bg-danger/10 p-4 text-sm text-danger">
          <p className="font-medium">Access to the rest of the app is paused.</p>
          <p className="mt-1 text-danger/90">
            Your subscription status is <span className="font-medium">{subscription.status.replace(/_/g, " ")}</span>.
            Contact your account owner or support to restore access.
          </p>
        </div>
      )}

      <div className="rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] p-4">
        <div className="flex items-center justify-between">
          <div>
            <p className="text-sm font-medium">Current plan</p>
            <p className="mt-1 text-2xl font-semibold">{currentPlan?.name ?? "No active plan"}</p>
          </div>
          {subscription && <StatusBadge status={subscription.status} />}
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

      <div>
        <p className="mb-3 text-sm font-medium">Available plans</p>
        <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
          {(plans ?? []).map((plan) => {
            const isCurrent = plan.id === currentPlan?.id;
            return (
              <div
                key={plan.id}
                className={
                  "rounded-lg border p-4 " +
                  (isCurrent ? "border-[var(--color-brand)]" : "border-[var(--color-border)]")
                }
              >
                <p className="font-medium">{plan.name}</p>
                <p className="mt-1 text-2xl font-semibold">
                  ${(plan.monthly_price_cents / 100).toLocaleString()}
                  <span className="text-sm font-normal text-[var(--color-text-muted)]">/mo</span>
                </p>
                <p className="mt-2 text-sm text-[var(--color-text-muted)]">{plan.description}</p>
                <ul className="mt-3 space-y-1 text-sm">
                  {(plan.features as string[]).map((f) => (
                    <li key={f}>&bull; {f}</li>
                  ))}
                </ul>
                {isCurrent ? (
                  <div className="mt-4">
                    <StatusBadge status="active" />
                  </div>
                ) : (
                  <form action={changePlan.bind(null, plan.id)} className="mt-4">
                    <Button type="submit" variant="ghost" size="sm" className="w-full">
                      Switch to {plan.name}
                    </Button>
                  </form>
                )}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
