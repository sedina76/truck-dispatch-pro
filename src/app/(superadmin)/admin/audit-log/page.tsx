import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { PlatformActivityFeed } from "@/components/superadmin/platform-activity-feed";
import type { ActivityEntry, SubscriptionStatus } from "@/lib/superadmin/platform-metrics";

// Fuller version of the Overview's Recent Platform Activity -- same real
// sources (organizations/organization_subscriptions/billing_records/
// activity_logs), just more rows and no 12-item cap. The activity_logs
// portion requires 0045's activity_logs_platform_admin_select policy; if
// it hasn't run yet, that query returns nothing under RLS (not an error)
// and this page still shows the other 3 real sources.
export default async function SuperAdminAuditLogPage() {
  const supabase = await createClient();

  const [{ data: orgs }, { data: subs }, { data: billing }, { data: logs }] = await Promise.all([
    supabase.from("organizations").select("id, name, created_at").order("created_at", { ascending: false }),
    supabase.from("organization_subscriptions").select("organization_id, status, updated_at").order("updated_at", { ascending: false }).limit(50),
    supabase.from("billing_records").select("id, organization_id, amount_cents, paid_at").eq("status", "paid").order("paid_at", { ascending: false }).limit(50),
    supabase.from("activity_logs").select("id, entity_type, action, created_at, organization_id").order("created_at", { ascending: false }).limit(50),
  ]);
  const orgById = new Map((orgs ?? []).map((o) => [o.id, o]));

  const entries: ActivityEntry[] = [];
  for (const org of orgs ?? []) {
    entries.push({ id: `org-${org.id}`, kind: "company_created", title: "Company created", detail: org.name, occurredAt: org.created_at });
  }
  for (const s of (subs ?? []) as unknown as { organization_id: string; status: SubscriptionStatus; updated_at: string }[]) {
    const org = orgById.get(s.organization_id);
    if (!org) continue;
    entries.push({ id: `sub-${s.organization_id}-${s.updated_at}`, kind: "subscription_status", title: `Subscription ${s.status.replace(/_/g, " ")}`, detail: org.name, occurredAt: s.updated_at });
  }
  for (const b of billing ?? []) {
    const org = orgById.get(b.organization_id);
    if (!org || !b.paid_at) continue;
    entries.push({ id: `bill-${b.id}`, kind: "payment_received", title: `Payment received -- $${(b.amount_cents / 100).toLocaleString(undefined, { minimumFractionDigits: 2 })}`, detail: org.name, occurredAt: b.paid_at });
  }
  for (const a of logs ?? []) {
    const org = orgById.get(a.organization_id);
    if (!org) continue;
    entries.push({ id: `log-${a.id}`, kind: "admin_action", title: `Platform admin: ${a.action.replace(/_/g, " ")}`, detail: org.name, occurredAt: a.created_at });
  }
  entries.sort((a, b) => new Date(b.occurredAt).getTime() - new Date(a.occurredAt).getTime());

  return (
    <div className="space-y-6">
      <PageHeader title="Audit Log" description="Every real, recorded platform-level event across all tenants." />
      {(logs ?? []).length === 0 && (
        <div className="rounded-xl border border-amber-500/20 bg-amber-500/5 p-4 text-[13px] text-amber-300">
          No explicit platform-admin-action log entries yet -- either none have happened since RUN_THIS_FOR_PLATFORM_CONSOLE_REDESIGN.sql was applied, or it hasn&apos;t been applied yet. Company/subscription/payment events below are still real.
        </div>
      )}
      <PlatformActivityFeed entries={entries.slice(0, 100)} />
    </div>
  );
}
