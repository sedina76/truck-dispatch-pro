import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { StatusBadge } from "@/components/ui/status-badge";
import { FormSelect } from "@/components/ui/form-field";
import { Button } from "@/components/ui/button";
import { updateOrgSubscription } from "../actions";
import { CompanyTabs, type CompanyTab } from "@/components/superadmin/company-tabs";
import { CompanyProfileForm } from "@/components/superadmin/company-profile-form";
import { CompanyAdminsPanel, type AdminRow } from "@/components/superadmin/company-admins-panel";
import { SuspendCompanyControl } from "@/components/superadmin/suspend-company-control";
import { PlatformMetricCard } from "@/components/superadmin/platform-metric-card";
import { Building2, Users, Truck, Package, Receipt, DollarSign, Calendar } from "lucide-react";
import Link from "next/link";

function money(cents: number): string {
  return `$${(cents / 100).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

const TAB_PARAM: Record<string, CompanyTab> = {
  overview: "Overview",
  profile: "Company Profile",
  admins: "Admins & Credentials",
  subscription: "Subscription",
  billing: "Billing",
  usage: "Usage",
  audit: "Audit History",
};

export default async function SuperAdminCompanyDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ tab?: string }>;
}) {
  const { id } = await params;
  const { tab } = await searchParams;
  const supabase = await createClient();
  const admin = createServiceRoleClient();

  const [{ data: org }, { data: subscription }, { data: plans }, { data: billingRecords }, { data: usageRows }, { data: profiles }, { data: auditRows }] =
    await Promise.all([
      supabase.from("organizations").select("*").eq("id", id).single(),
      supabase.from("organization_subscriptions").select("*, subscription_plans(*)").eq("organization_id", id).maybeSingle(),
      supabase.from("subscription_plans").select("id, name, monthly_price_cents").eq("is_active", true).order("monthly_price_cents"),
      supabase.from("billing_records").select("*").eq("organization_id", id).order("created_at", { ascending: false }).limit(25),
      supabase.rpc("get_org_usage_counts", { p_org_id: id }),
      supabase.from("profiles").select("id, full_name, email, phone, role, is_active, created_at").eq("organization_id", id).order("created_at"),
      supabase
        .from("activity_logs")
        .select("id, action, entity_type, entity_id, created_at, changes, actor_id, profiles!activity_logs_actor_id_fkey(full_name)")
        .eq("organization_id", id)
        .order("created_at", { ascending: false })
        .limit(50),
    ]);

  if (!org) notFound();

  const currentPlan = (subscription as unknown as { subscription_plans: { name: string; monthly_price_cents: number } | null } | null)?.subscription_plans;
  const usage = (usageRows as unknown as { user_count: number; truck_count: number; active_load_count: number }[] | null)?.[0];

  // Last-sign-in is auth.users data, not profiles -- fetched per-admin via
  // the Admin API. Bounded by this ONE company's own admin count (a small,
  // fixed number in practice), not proportional to platform size -- not
  // the N-per-company pattern the platform-wide dashboard was told to avoid.
  const adminRows: AdminRow[] = await Promise.all(
    (profiles ?? []).map(async (p) => {
      const { data: authUser } = await admin.auth.admin.getUserById(p.id);
      const ownerCount = (profiles ?? []).filter((x) => x.role === "owner").length;
      return {
        id: p.id,
        fullName: p.full_name,
        email: p.email,
        phone: p.phone,
        role: p.role,
        isActive: p.is_active,
        createdAt: p.created_at,
        lastSignInAt: authUser?.user?.last_sign_in_at ?? null,
        isLastOwner: p.role === "owner" && ownerCount === 1,
      };
    })
  );

  const [{ count: driverCount }, { count: loadCount }, { count: invoiceCount }] = await Promise.all([
    admin.from("drivers").select("id", { count: "exact", head: true }).eq("organization_id", id),
    admin.from("loads").select("id", { count: "exact", head: true }).eq("organization_id", id),
    admin.from("invoices").select("id", { count: "exact", head: true }).eq("organization_id", id),
  ]);

  const { data: lastActivity } = await supabase
    .from("activity_logs")
    .select("created_at")
    .eq("organization_id", id)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  const auditEntries = (auditRows ?? []) as unknown as {
    id: string;
    action: string;
    entity_type: string;
    created_at: string;
    changes: Record<string, unknown> | null;
    profiles: { full_name: string } | null;
  }[];

  const initialTab = TAB_PARAM[tab ?? ""] ?? "Overview";

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="flex items-center gap-2.5">
            <div className="flex size-9 items-center justify-center rounded-lg bg-blue-500/10 text-blue-400">
              <Building2 className="size-4.5" />
            </div>
            <div>
              <div className="flex items-center gap-2">
                <h1 className="text-lg font-semibold text-slate-50">{org.name}</h1>
                {subscription?.status === "paused" && (
                  <span className="inline-flex items-center gap-1 rounded-full border border-red-500/30 bg-red-500/10 px-2 py-0.5 text-[10.5px] font-semibold uppercase tracking-wide text-red-400">
                    Suspended
                  </span>
                )}
              </div>
              <p className="text-[12.5px] text-slate-500">
                {currentPlan?.name ?? "No plan"} &middot; <StatusBadge status={subscription?.status ?? null} /> &middot; /{org.slug}
              </p>
            </div>
          </div>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Link href={`/admin/companies/${id}/edit`} className="flex h-9 items-center rounded-lg border border-slate-700 px-3 text-[12.5px] font-medium text-slate-300 hover:bg-slate-800">
            Edit Company
          </Link>
          <Link href={`/admin/companies/${id}/admins/new`} className="flex h-9 items-center rounded-lg border border-slate-700 px-3 text-[12.5px] font-medium text-slate-300 hover:bg-slate-800">
            Add Admin
          </Link>
          <Link href={`/admin/companies/${id}?tab=subscription`} className="flex h-9 items-center rounded-lg border border-slate-700 px-3 text-[12.5px] font-medium text-slate-300 hover:bg-slate-800">
            Manage Subscription
          </Link>
          <SuspendCompanyControl orgId={id} companyName={org.name} planId={subscription?.plan_id ?? null} currentStatus={subscription?.status ?? null} />
        </div>
      </div>

      <CompanyTabs
        initialTab={initialTab}
        panels={{
          Overview: (
            <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
              <PlatformMetricCard label="Plan" value={currentPlan?.name ?? "No plan"} icon={Building2} tone="blue" />
              <PlatformMetricCard label="MRR" value={money(subscription?.status === "active" ? currentPlan?.monthly_price_cents ?? 0 : 0)} icon={DollarSign} tone="purple" />
              <PlatformMetricCard label="Users" value={usage?.user_count ?? 0} icon={Users} tone="emerald" />
              <PlatformMetricCard label="Drivers" value={driverCount ?? 0} icon={Users} tone="emerald" />
              <PlatformMetricCard label="Loads" value={loadCount ?? 0} icon={Package} tone="blue" />
              <PlatformMetricCard label="Active Loads" value={usage?.active_load_count ?? 0} icon={Truck} tone="blue" />
              <PlatformMetricCard label="Invoices" value={invoiceCount ?? 0} icon={Receipt} tone="amber" />
              <PlatformMetricCard label="Created" value={new Date(org.created_at).toLocaleDateString()} icon={Calendar} tone="neutral" sub={lastActivity ? `Last activity ${new Date(lastActivity.created_at).toLocaleDateString()}` : "No recorded activity yet"} />
            </div>
          ),
          "Company Profile": <CompanyProfileForm org={org} />,
          "Admins & Credentials": <CompanyAdminsPanel orgId={id} admins={adminRows} />,
          Subscription: (
            <div className="max-w-lg rounded-xl border border-slate-800 bg-slate-900/60 p-5">
              <p className="mb-4 text-sm font-semibold text-slate-100">Manage Subscription</p>
              <form action={updateOrgSubscription.bind(null, id)} className="flex flex-wrap items-end gap-4">
                <div className="w-56">
                  <FormSelect
                    label="Plan"
                    name="plan_id"
                    defaultValue={subscription?.plan_id ?? plans?.[0]?.id}
                    options={(plans ?? []).map((p) => ({ value: p.id, label: `${p.name} -- ${money(p.monthly_price_cents)}/mo` }))}
                  />
                </div>
                <div className="w-48">
                  <FormSelect
                    label="Status"
                    name="status"
                    defaultValue={subscription?.status ?? "trialing"}
                    options={[
                      { value: "trialing", label: "Trialing" },
                      { value: "active", label: "Active" },
                      { value: "past_due", label: "Past Due" },
                      { value: "paused", label: "Paused (suspended)" },
                      { value: "canceled", label: "Canceled" },
                      { value: "incomplete", label: "Incomplete" },
                    ]}
                  />
                </div>
                <Button type="submit">Save</Button>
              </form>
              <p className="mt-3 text-xs text-slate-500">
                Setting status to <span className="font-medium text-slate-300">Past Due</span>, <span className="font-medium text-slate-300">Paused</span>, or{" "}
                <span className="font-medium text-slate-300">Canceled</span> blocks this company from the app until it&apos;s changed back (enforced in middleware).
              </p>
            </div>
          ),
          Billing: (
            <div className="overflow-x-auto rounded-xl border border-slate-800 bg-slate-900/60">
              <table className="w-full text-[13px]">
                <thead>
                  <tr className="border-b border-slate-800 text-left text-[10.5px] font-semibold uppercase tracking-wide text-slate-500">
                    <th className="px-4 py-2.5">Date</th>
                    <th className="px-3 py-2.5 text-right">Amount</th>
                    <th className="px-3 py-2.5">Status</th>
                  </tr>
                </thead>
                <tbody>
                  {(billingRecords ?? []).map((b) => (
                    <tr key={b.id} className="border-b border-slate-800/70 last:border-0">
                      <td className="px-4 py-2.5 text-slate-300">{new Date(b.created_at).toLocaleDateString()}</td>
                      <td className="px-3 py-2.5 text-right font-medium text-purple-400">{money(b.amount_cents)}</td>
                      <td className="px-3 py-2.5"><StatusBadge status={b.status} /></td>
                    </tr>
                  ))}
                  {(!billingRecords || billingRecords.length === 0) && (
                    <tr><td colSpan={3} className="px-4 py-8 text-center text-sm text-slate-500">No billing records yet.</td></tr>
                  )}
                </tbody>
              </table>
            </div>
          ),
          Usage: (
            <div className="grid grid-cols-2 gap-3 md:grid-cols-3">
              <PlatformMetricCard label="Users" value={usage?.user_count ?? 0} icon={Users} tone="blue" />
              <PlatformMetricCard label="Trucks" value={usage?.truck_count ?? 0} icon={Truck} tone="emerald" />
              <PlatformMetricCard label="Active Loads" value={usage?.active_load_count ?? 0} icon={Package} tone="amber" />
              <PlatformMetricCard label="Storage" value="Unavailable" icon={Receipt} tone="neutral" sub="No storage-usage tracking exists in this schema" />
            </div>
          ),
          "Audit History": (
            <div className="space-y-2.5">
              {auditEntries.length === 0 ? (
                <p className="text-sm text-slate-500">No platform-admin actions recorded for this company yet.</p>
              ) : (
                auditEntries.map((e) => (
                  <div key={e.id} className="flex items-center justify-between rounded-lg border border-slate-800 bg-slate-900/60 px-3.5 py-2.5 text-[12.5px]">
                    <div>
                      <p className="font-medium text-slate-200">{e.action.replace(/_/g, " ")}</p>
                      <p className="text-slate-500">by {e.profiles?.full_name ?? "Unknown"}</p>
                    </div>
                    <span className="text-[11px] text-slate-500">{new Date(e.created_at).toLocaleString()}</span>
                  </div>
                ))
              )}
            </div>
          ),
        }}
      />
    </div>
  );
}
