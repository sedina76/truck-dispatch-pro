import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { Building2, Users, DollarSign, TrendingUp, AlertTriangle, ShieldAlert, PlusCircle, CreditCard, FileText, ShieldCheck, HeartPulse, ScrollText, Plus } from "lucide-react";
import { getPlatformOverview, formatCents } from "@/lib/superadmin/platform-metrics";
import { PlatformMetricCard } from "@/components/superadmin/platform-metric-card";
import { PlatformChartPanel } from "@/components/superadmin/platform-chart-panel";
import { SubscriptionBreakdown } from "@/components/superadmin/subscription-breakdown";
import { CompanyOverviewTable } from "@/components/superadmin/company-overview-table";
import { PlatformActivityFeed } from "@/components/superadmin/platform-activity-feed";
import { SystemStatusCard } from "@/components/superadmin/system-status-card";
import { QuickActionCard } from "@/components/superadmin/quick-action-card";
import { RefreshButton } from "@/components/superadmin/refresh-button";

export default async function SuperAdminDashboardPage() {
  const supabase = await createClient();
  const [{ data: { user } }, overview] = await Promise.all([supabase.auth.getUser(), getPlatformOverview()]);
  const { data: admin } = user ? await supabase.from("platform_admins").select("full_name").eq("id", user.id).maybeSingle() : { data: null };

  const { totals, companyGrowth, breakdown, companies, activity, operational, usersByOrg } = overview;

  return (
    <div className="space-y-5">
      {/* Header */}
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-xl font-semibold tracking-tight text-slate-50">Platform Overview</h1>
          <p className="mt-1 text-sm text-slate-400">Real-time overview of your Truck Dispatch platform.</p>
        </div>
        <div className="flex items-center gap-3">
          <span className="flex items-center gap-1.5 rounded-full border border-emerald-500/20 bg-emerald-500/10 px-2.5 py-1 text-[11px] font-medium text-emerald-400">
            <HeartPulse className="size-3" /> Operational
          </span>
          <RefreshButton />
          <div className="flex items-center gap-2 rounded-lg border border-slate-800 bg-slate-900/60 px-2.5 py-1.5">
            <div className="flex size-6 items-center justify-center rounded-full bg-blue-500/20 text-[10px] font-semibold text-blue-300">
              {(admin?.full_name ?? "PA").slice(0, 2).toUpperCase()}
            </div>
            <span className="text-[12px] font-medium text-slate-200">{admin?.full_name ?? "Platform Admin"}</span>
          </div>
        </div>
      </div>

      {/* Top KPI row */}
      <div className="grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-6">
        <PlatformMetricCard label="Total Companies" value={totals.companyCount} icon={Building2} tone="blue" />
        <PlatformMetricCard label="Active Subscriptions" value={totals.activeCount} icon={Users} tone="emerald" sub={`${totals.trialingCount} trialing`} />
        <PlatformMetricCard label="MRR" value={formatCents(totals.mrrCents)} icon={DollarSign} tone="purple" />
        <PlatformMetricCard label="ARR" value={formatCents(totals.arrCents)} icon={TrendingUp} tone="purple" sub="MRR x 12" />
        <PlatformMetricCard label="Past Due" value={totals.pastDueCount} icon={AlertTriangle} tone={totals.pastDueCount > 0 ? "red" : "neutral"} />
        <PlatformMetricCard label="At Risk" value={totals.atRiskCount} icon={ShieldAlert} tone={totals.atRiskCount > 0 ? "amber" : "neutral"} />
      </div>

      {/* Analytics row: MRR/Growth chart, Subscription Breakdown, and the
          "Right Now" operational panel side by side -- all three are
          similar height now that the chart panel has been compacted. */}
      <div className="grid grid-cols-1 gap-3 xl:grid-cols-4">
        <div className="xl:col-span-2">
          <PlatformChartPanel mrrCents={totals.mrrCents} arrCents={totals.arrCents} growth={companyGrowth} />
        </div>
        <SubscriptionBreakdown slices={breakdown} activeCount={totals.activeCount} trialingCount={totals.trialingCount} totalMrrCents={totals.mrrCents} />
        <SystemStatusCard
          activeUsers={operational.activeUsers}
          liveDispatches={operational.liveDispatches}
          openInvoices={operational.openInvoices}
          trialingCompanies={totals.trialingCount}
          available={operational.available}
        />
      </div>

      {/* Companies (primary tenant-management surface -- given more
          relative width than the activity feed) + Recent Platform Activity */}
      <div className="grid grid-cols-1 gap-3 xl:grid-cols-3">
        <div className="xl:col-span-2">
          <div className="mb-3 flex items-center justify-between">
            <p className="text-sm font-semibold text-slate-100">Companies</p>
            <div className="flex items-center gap-3">
              <Link
                href="/admin/companies/new"
                className="flex items-center gap-1 rounded-lg bg-blue-500 px-2.5 py-1.5 text-[11.5px] font-medium text-white hover:bg-blue-400"
              >
                <Plus className="size-3.5" /> Add Company
              </Link>
              <Link href="/admin/companies" className="text-[11px] font-medium text-blue-400 hover:text-blue-300">
                View all &rarr;
              </Link>
            </div>
          </div>
          <CompanyOverviewTable companies={companies.slice(0, 8)} usersByOrg={usersByOrg} />
        </div>
        <PlatformActivityFeed entries={activity} />
      </div>

      {/* Quick actions */}
      <div>
        <p className="mb-3 text-sm font-semibold text-slate-100">Quick Actions</p>
        <div className="grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-6">
          <QuickActionCard href="/admin/companies/new" icon={PlusCircle} label="Add Company" description="Create a new tenant" />
          <QuickActionCard href="/admin/subscriptions" icon={CreditCard} label="Manage Plans" description="Catalog & tenant plans" />
          <QuickActionCard href="/admin/billing" icon={FileText} label="View Billing" description="Platform invoices" />
          <QuickActionCard href="/admin/admins" icon={ShieldCheck} label="Platform Admins" description="Console access" />
          <QuickActionCard href="/admin/system-health" icon={HeartPulse} label="System Health" description="Data availability" />
          <QuickActionCard href="/admin/audit-log" icon={ScrollText} label="Audit Log" description="Platform-wide events" />
        </div>
      </div>
    </div>
  );
}
