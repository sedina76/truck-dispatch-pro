import Link from "next/link";
import { ShieldAlert, Activity, CheckSquare, TrendingUp, Building2, Radio, MapPin } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { StatusBadge } from "@/components/ui/status-badge";
import { RevenueChart, type RevenuePoint } from "@/components/dashboard/revenue-chart";
import { StatusBarChart, type StatusPoint } from "@/components/dashboard/status-bar-chart";
import { StatusDonutChart, type DonutSlice } from "@/components/dashboard/status-donut-chart";
import { KpiScroller } from "@/components/dashboard/kpi-scroller";
import { getDashboardKpis } from "./kpi-data";
import { EmptyState } from "@/components/ui/empty-state";
import { COMPLETED_LOAD_STATUSES, INVOICED_LOAD_STATUSES } from "@/lib/loads/status";
import { getLatestDocumentsByEntity } from "@/lib/documents/latest-document";
import { formatMoney } from "@/lib/collections/types";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";

const STATUS_COLORS: Record<string, string> = {
  assigned: "#94a3b8",
  accepted: "#60a5fa",
  en_route_to_pickup: "#38bdf8",
  at_pickup: "#38bdf8",
  loaded: "#818cf8",
  en_route_to_delivery: "#2f5be0",
  at_delivery: "#2f5be0",
  delivered: "#0ea472",
  completed: "#0ea472",
  cancelled: "#dc3545",
};

// "Delivered" here is deliberately just COMPLETED_LOAD_STATUSES (delivered +
// pod_received) -- not invoiced/closed too -- so this slice's count always
// matches the canonical "completed" count used everywhere else (Loads page,
// Driver Trip History). Invoiced/closed loads get their own bucket instead
// of being silently folded into "Delivered", which is what caused this
// chart to disagree with other completed-trip counts before.
const LOAD_STATUS_GROUPS: { label: string; statuses: string[]; color: string }[] = [
  { label: "Pending", statuses: ["draft", "posted"], color: "#94a3b8" },
  { label: "Assigned", statuses: ["booked", "dispatched"], color: "#60a5fa" },
  { label: "Picked Up", statuses: ["at_pickup"], color: "#818cf8" },
  { label: "In Transit", statuses: ["in_transit", "at_delivery"], color: "#2f5be0" },
  { label: "Delivered", statuses: [...COMPLETED_LOAD_STATUSES], color: "#0ea472" },
  { label: "Invoiced / Closed", statuses: [...INVOICED_LOAD_STATUSES], color: "#0b8a5f" },
  { label: "Delayed", statuses: ["problem"], color: "#d68a04" },
  { label: "Cancelled", statuses: ["cancelled"], color: "#dc3545" },
];

function pctDelta(current: number, previous: number): number | undefined {
  if (previous === 0) return undefined;
  return ((current - previous) / previous) * 100;
}

export default async function DashboardPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: profile } = await supabase.from("profiles").select("full_name, organization_id").eq("id", user!.id).single();
  const orgId = profile?.organization_id ?? null;

  const [
    kpiTiles,
    expiringCompliance,
    loadsForRevenue,
    paymentsForRevenue,
    dispatchStatusRows,
    activityRows,
    taskRows,
    brokerRevenueRows,
    loadStatusRows,
    trackingRows,
    org,
    counts,
    deliveredLoadsForPod,
    collectionsSummaryRes,
    collectionsQueueRes,
    profitabilitySummaryRes,
    expenseSummaryRes,
  ] = await Promise.all([
    getDashboardKpis(),
    supabase.rpc("get_expiring_compliance_items", { p_days_ahead: 30 }),
    supabase.from("loads").select("rate, created_at"),
    supabase.from("payments").select("amount, received_at"),
    supabase.from("dispatches").select("status"),
    supabase
      .from("activity_logs")
      .select("id, entity_type, action, created_at, profiles(full_name)")
      .order("created_at", { ascending: false })
      .limit(8),
    supabase
      .from("tasks")
      .select("id, title, priority, due_at")
      .not("status", "in", "(completed,cancelled)")
      .order("due_at", { ascending: true, nullsFirst: false })
      .limit(6),
    supabase.from("loads").select("rate, brokers(company_name)").not("broker_id", "is", null),
    supabase.from("loads").select("status"),
    supabase
      .from("load_tracking_events")
      .select("id, location_description, source, occurred_at, status, loads(load_number)")
      .order("occurred_at", { ascending: false })
      .limit(6),
    orgId
      ? supabase
          .from("organizations")
          .select("name, mc_number, dot_number, ein, business_phone, business_email, website, address_line1, city, state")
          .eq("id", orgId)
          .single()
      : Promise.resolve({ data: null }),
    orgId
      ? Promise.all([
          supabase.from("drivers").select("id", { count: "exact", head: true }).eq("status", "active"),
          supabase.from("trucks").select("id", { count: "exact", head: true }).eq("status", "active"),
          supabase.from("trailers").select("id", { count: "exact", head: true }).eq("status", "active"),
          supabase.from("customers").select("id", { count: "exact", head: true }),
          supabase.from("brokers").select("id", { count: "exact", head: true }),
          supabase.from("carriers").select("id", { count: "exact", head: true }),
        ])
      : Promise.resolve([{ count: 0 }, { count: 0 }, { count: 0 }, { count: 0 }, { count: 0 }, { count: 0 }]),
    supabase.from("loads").select("id").eq("status", "delivered"),
    // Collections alert: same canonical get_collections_summary()/
    // get_collections_queue() (0027_collections.sql) the Collections page
    // itself uses -- one compact alert area, not several new KPI cards.
    supabase.rpc("get_collections_summary").single(),
    supabase.rpc("get_collections_queue"),
    // Compact profitability KPIs (month-to-date) -- get_profitability_summary()
    // (0037_profitability.sql), the same canonical get_load_profitability()
    // source Reports -> Profitability uses. Never a separately-computed figure.
    supabase.rpc("get_profitability_summary", {
      p_period_start: new Date(new Date().getFullYear(), new Date().getMonth(), 1).toISOString().slice(0, 10),
      p_period_end: null,
    }).single(),
    // Compact expense KPIs (month-to-date) -- get_expense_summary()
    // (0040_expense_cost_management.sql), the same canonical source
    // Reports -> Expenses uses. Deliberately just 3 figures per spec: total
    // MTD, direct load costs, and unapproved -- not an overloaded strip.
    supabase.rpc("get_expense_summary", {
      p_period_start: new Date(new Date().getFullYear(), new Date().getMonth(), 1).toISOString().slice(0, 10),
      p_period_end: null,
    }).single(),
  ]);

  // Delivered Loads Missing POD: computed here, not stored -- uses the same
  // canonical "latest document per entity" helper as the load/invoice/
  // driver-trip pages (src/lib/documents/latest-document.ts), so "missing"
  // always means the same thing everywhere: the load's MOST RECENT POD
  // isn't verified, not "was any POD ever verified" (which can disagree
  // once a verified POD gets superseded by a newer upload).
  const latestPodByLoadId = await getLatestDocumentsByEntity(supabase, "load", "pod");
  const deliveredLoadsMissingPod = (deliveredLoadsForPod.data ?? []).filter(
    (l) => latestPodByLoadId.get(l.id)?.is_verified !== true
  );
  const [activeDriversCount, activeTrucksCount, activeTrailersCount, customerCount, brokerCount, carrierCount] = counts;

  const collectionsSummary = collectionsSummaryRes.data as { total_overdue: number; overdue_invoices: number } | null;
  const collectionsQueueRows = (collectionsQueueRes.data ?? []) as { promise_effective_status: string | null; next_follow_up_at: string | null }[];
  const brokenPromiseCount = collectionsQueueRows.filter((r) => r.promise_effective_status === "broken").length;
  const followUpsDueCount = collectionsQueueRows.filter((r) => r.next_follow_up_at && new Date(r.next_follow_up_at) <= new Date()).length;
  const hasCollectionsAlert = (collectionsSummary?.overdue_invoices ?? 0) > 0 || brokenPromiseCount > 0 || followUpsDueCount > 0;

  const months: { key: string; label: string; booked: number; collected: number }[] = [];
  for (let i = 5; i >= 0; i--) {
    const d = new Date();
    d.setDate(1);
    d.setMonth(d.getMonth() - i);
    months.push({
      key: `${d.getFullYear()}-${d.getMonth()}`,
      label: d.toLocaleString("en-US", { month: "short" }),
      booked: 0,
      collected: 0,
    });
  }
  for (const load of loadsForRevenue.data ?? []) {
    const d = new Date(load.created_at);
    const month = months.find((m) => m.key === `${d.getFullYear()}-${d.getMonth()}`);
    if (month) month.booked += Number(load.rate);
  }
  for (const payment of paymentsForRevenue.data ?? []) {
    const d = new Date(payment.received_at);
    const month = months.find((m) => m.key === `${d.getFullYear()}-${d.getMonth()}`);
    if (month) month.collected += Number(payment.amount);
  }
  const revenueData: RevenuePoint[] = months.map(({ label, booked, collected }) => ({ label, booked, collected }));
  const thisMonthRevenue = months[months.length - 1]?.booked ?? 0;
  const lastMonthRevenue = months[months.length - 2]?.booked ?? 0;

  const statusCounts = new Map<string, number>();
  for (const row of dispatchStatusRows.data ?? []) {
    statusCounts.set(row.status, (statusCounts.get(row.status) ?? 0) + 1);
  }
  const statusData: StatusPoint[] = Array.from(statusCounts.entries())
    .map(([status, count]) => ({
      status: status.replace(/_/g, " "),
      count,
      color: STATUS_COLORS[status] ?? "#94a3b8",
    }))
    .sort((a, b) => b.count - a.count);

  const loadStatusCounts = new Map<string, number>();
  for (const row of loadStatusRows.data ?? []) {
    loadStatusCounts.set(row.status, (loadStatusCounts.get(row.status) ?? 0) + 1);
  }
  const loadDonutData: DonutSlice[] = LOAD_STATUS_GROUPS.map((group) => ({
    name: group.label,
    value: group.statuses.reduce((sum, s) => sum + (loadStatusCounts.get(s) ?? 0), 0),
    color: group.color,
  })).filter((slice) => slice.value > 0);

  const tracking = (trackingRows.data ?? []) as unknown as {
    id: string;
    location_description: string | null;
    source: string;
    occurred_at: string;
    status: string | null;
    loads: { load_number: string } | null;
  }[];

  const brokerTotals = new Map<string, number>();
  for (const row of (brokerRevenueRows.data ?? []) as unknown as { rate: number; brokers: { company_name: string } | null }[]) {
    const name = row.brokers?.company_name ?? "Unknown";
    brokerTotals.set(name, (brokerTotals.get(name) ?? 0) + Number(row.rate));
  }
  const topBrokers = Array.from(brokerTotals.entries())
    .map(([name, total]) => ({ name, total }))
    .sort((a, b) => b.total - a.total)
    .slice(0, 5);

  const profitability = profitabilitySummaryRes.data as {
    load_count: number;
    total_revenue: number;
    total_gross_profit: number;
    avg_margin_percent: number | null;
    missing_cost_count: number;
    missing_revenue_count: number;
  } | null;

  const expenseSummary = expenseSummaryRes.data as {
    total_count: number; total_amount: number; direct_load_total: number;
    pending_count: number; pending_amount: number;
  } | null;

  const activity = (activityRows.data ?? []) as unknown as {
    id: string;
    entity_type: string;
    action: string;
    created_at: string;
    profiles: { full_name: string } | null;
  }[];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Dashboard", href: "/dashboard" }]} />
      <div>
        <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">
          Welcome back{profile?.full_name ? `, ${profile.full_name.split(" ")[0]}` : ""}
        </h1>
        <p className="mt-0.5 text-xs text-muted-foreground">
          {new Date().toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric" })} -- here&apos;s what&apos;s happening across your operation today.
        </p>
      </div>

      <KpiScroller tiles={kpiTiles} />

      <DesktopKpiStrip>
        <DesktopKpiBox label="MTD Profitable Loads" value={profitability?.load_count ?? 0} href="/reports/load-margin" />
        <DesktopKpiBox label="MTD Revenue" value={`$${Number(profitability?.total_revenue ?? 0).toLocaleString()}`} href="/reports/profitability" />
        <DesktopKpiBox
          label="MTD Gross Profit"
          value={`$${Number(profitability?.total_gross_profit ?? 0).toLocaleString()}`}
          tone={(profitability?.total_gross_profit ?? 0) >= 0 ? "success" : "danger"}
          href="/reports/profitability"
        />
        <DesktopKpiBox
          label="MTD Avg Margin %"
          value={profitability?.avg_margin_percent != null ? `${Number(profitability.avg_margin_percent).toFixed(1)}%` : "--"}
          tone="primary"
          href="/reports/profitability"
        />
      </DesktopKpiStrip>

      <DesktopKpiStrip>
        <DesktopKpiBox label="Expenses This Month" value={`$${Number(expenseSummary?.total_amount ?? 0).toLocaleString()}`} href="/reports/expenses" />
        <DesktopKpiBox label="Direct Load Costs" value={`$${Number(expenseSummary?.direct_load_total ?? 0).toLocaleString()}`} href="/reports/expenses" />
        <DesktopKpiBox
          label="Unapproved Expenses"
          value={`${expenseSummary?.pending_count ?? 0} ($${Number(expenseSummary?.pending_amount ?? 0).toLocaleString()})`}
          tone={(expenseSummary?.pending_count ?? 0) > 0 ? "warning" : "neutral"}
          href="/expenses?status=submitted"
        />
      </DesktopKpiStrip>

      {deliveredLoadsMissingPod.length > 0 && (
        <Link
          href="/loads?pod_missing=1"
          className="flex items-center justify-between rounded-md border border-warning/30 bg-warning/5 px-3 py-1.5 text-[12.5px] transition-colors hover:bg-warning/10"
        >
          <span className="flex items-center gap-2">
            <ShieldAlert className="size-3.5 text-warning" />
            <span className="font-medium">{deliveredLoadsMissingPod.length}</span> delivered load
            {deliveredLoadsMissingPod.length === 1 ? "" : "s"} missing verified Proof of Delivery
          </span>
          <span className="text-[11.5px] font-medium text-primary">View loads &rarr;</span>
        </Link>
      )}

      {hasCollectionsAlert && (
        <Link
          href="/collections"
          className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-danger/30 bg-danger/5 px-3 py-1.5 text-[12.5px] transition-colors hover:bg-danger/10"
        >
          <span className="flex flex-wrap items-center gap-x-4 gap-y-1">
            <span className="flex items-center gap-2 font-medium">
              <ShieldAlert className="size-3.5 text-danger" />
              {formatMoney(collectionsSummary?.total_overdue)} overdue across {collectionsSummary?.overdue_invoices ?? 0} invoice
              {collectionsSummary?.overdue_invoices === 1 ? "" : "s"}
            </span>
            {brokenPromiseCount > 0 && <span>{brokenPromiseCount} broken promise{brokenPromiseCount === 1 ? "" : "s"}</span>}
            {followUpsDueCount > 0 && <span>{followUpsDueCount} follow-up{followUpsDueCount === 1 ? "" : "s"} due</span>}
          </span>
          <span className="text-[11.5px] font-medium text-primary">View Collections &rarr;</span>
        </Link>
      )}

      <div className="grid grid-cols-1 gap-5 xl:grid-cols-3">
        <Card className="xl:col-span-2">
          <CardHeader className="flex-row items-center justify-between space-y-0">
            <div>
              <CardTitle>Revenue Trend</CardTitle>
              <CardDescription>Booked vs. collected over the last 6 months</CardDescription>
            </div>
            <div
              className={`flex items-center gap-1 text-xs font-medium ${
                thisMonthRevenue >= lastMonthRevenue ? "text-success" : "text-danger"
              }`}
            >
              <TrendingUp className="size-3.5" />
              {lastMonthRevenue > 0
                ? `${Math.abs(pctDelta(thisMonthRevenue, lastMonthRevenue) ?? 0).toFixed(0)}% MoM`
                : "--"}
            </div>
          </CardHeader>
          <CardContent>
            <RevenueChart data={revenueData} />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Dispatch Pipeline</CardTitle>
            <CardDescription>Live dispatches by status</CardDescription>
          </CardHeader>
          <CardContent>
            {statusData.length === 0 ? (
              <EmptyState title="No dispatches yet" description="Assign a load to see the pipeline fill in." />
            ) : (
              <StatusBarChart data={statusData} />
            )}
          </CardContent>
        </Card>
      </div>

      <div className="grid grid-cols-1 gap-5 lg:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle>Loads by Status</CardTitle>
            <CardDescription>Where every load stands right now</CardDescription>
          </CardHeader>
          <CardContent>
            {loadDonutData.length === 0 ? (
              <EmptyState title="No loads yet" description="Book a load to see the breakdown." />
            ) : (
              <StatusDonutChart data={loadDonutData} />
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Radio className="size-4 text-primary" />
              Load Tracking
            </CardTitle>
            <CardDescription>Latest check-calls and status updates</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            {tracking.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                No tracking events logged yet. Connect an ELD/telematics provider under Settings &rarr; Integrations, or log check-calls manually.
              </p>
            ) : (
              tracking.map((event) => (
                <div key={event.id} className="flex items-start justify-between gap-2 text-sm">
                  <div className="min-w-0">
                    <p className="truncate font-medium">{event.loads?.load_number ?? "Load"}</p>
                    <p className="flex items-center gap-1 truncate text-xs text-muted-foreground">
                      <MapPin className="size-3 shrink-0" />
                      {event.location_description ?? "Location not recorded"}
                    </p>
                  </div>
                  <div className="shrink-0 text-right">
                    {event.status && <StatusBadge status={event.status} />}
                    <p className="mt-1 text-[11px] text-muted-foreground">{new Date(event.occurred_at).toLocaleString()}</p>
                  </div>
                </div>
              ))
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Building2 className="size-4 text-secondary" />
              Company Overview
            </CardTitle>
            <CardDescription>{org.data?.name ?? "Your organization"}</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <div className="grid grid-cols-2 gap-x-3 gap-y-2 text-xs text-muted-foreground">
              <span>MC# {org.data?.mc_number ?? "--"}</span>
              <span>DOT# {org.data?.dot_number ?? "--"}</span>
              <span className="col-span-2 truncate">{org.data?.business_email ?? "--"}</span>
            </div>
            <div className="grid grid-cols-3 gap-3 border-t border-border pt-3">
              <MiniStat label="Drivers" value={activeDriversCount.count ?? 0} />
              <MiniStat label="Trucks" value={activeTrucksCount.count ?? 0} />
              <MiniStat label="Trailers" value={activeTrailersCount.count ?? 0} />
              <MiniStat label="Customers" value={customerCount.count ?? 0} />
              <MiniStat label="Brokers" value={brokerCount.count ?? 0} />
              <MiniStat label="Carriers" value={carrierCount.count ?? 0} />
            </div>
            <Link href="/settings/organization" className="block pt-1 text-xs font-medium text-primary hover:underline">
              Edit company profile &rarr;
            </Link>
          </CardContent>
        </Card>
      </div>

      <div className="grid grid-cols-1 gap-5 lg:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <ShieldAlert className="size-4 text-danger" />
              Compliance Alerts
            </CardTitle>
            <CardDescription>Expiring within 30 days</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            {!Array.isArray(expiringCompliance.data) || expiringCompliance.data.length === 0 ? (
              <p className="text-sm text-muted-foreground">Nothing expiring soon. You&apos;re covered.</p>
            ) : (
              (expiringCompliance.data as { id: string; entity_type: string; item_type: string; expiry_date: string; status: string }[])
                .slice(0, 5)
                .map((item) => (
                  <div key={item.id} className="flex items-center justify-between gap-2">
                    <div className="min-w-0">
                      <p className="truncate text-sm font-medium capitalize">{item.item_type.replace(/_/g, " ")}</p>
                      <p className="text-xs text-muted-foreground capitalize">{item.entity_type}</p>
                    </div>
                    <StatusBadge status={item.status} />
                  </div>
                ))
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <CheckSquare className="size-4 text-primary" />
              Upcoming Tasks
            </CardTitle>
            <CardDescription>Open follow-ups across the team</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            {!taskRows.data || taskRows.data.length === 0 ? (
              <p className="text-sm text-muted-foreground">No open tasks. Nice work.</p>
            ) : (
              taskRows.data.map((task) => (
                <div key={task.id} className="flex items-center justify-between gap-2">
                  <p className="min-w-0 truncate text-sm font-medium">{task.title}</p>
                  <span className="shrink-0 text-xs text-muted-foreground">
                    {task.due_at ? new Date(task.due_at).toLocaleDateString() : "--"}
                  </span>
                </div>
              ))
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Activity className="size-4 text-secondary" />
              Recent Activity
            </CardTitle>
            <CardDescription>Latest changes across your workspace</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            {activity.length === 0 ? (
              <p className="text-sm text-muted-foreground">Activity from your team will show up here.</p>
            ) : (
              activity.map((event) => (
                <div key={event.id} className="text-sm">
                  <p>
                    <span className="font-medium">{event.profiles?.full_name ?? "Someone"}</span>{" "}
                    <span className="text-muted-foreground">{event.action}</span>{" "}
                    <span className="capitalize">a {event.entity_type}</span>
                  </p>
                  <p className="text-xs text-muted-foreground">{new Date(event.created_at).toLocaleString()}</p>
                </div>
              ))
            )}
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Top Brokers by Revenue</CardTitle>
          <CardDescription>Where your booked freight value is coming from</CardDescription>
        </CardHeader>
        <CardContent>
          {topBrokers.length === 0 ? (
            <EmptyState title="No broker revenue yet" description="Book loads through a broker to see them ranked here." />
          ) : (
            <div className="space-y-3">
              {topBrokers.map((broker, i) => {
                const max = topBrokers[0].total || 1;
                return (
                  <div key={broker.name} className="flex items-center gap-3">
                    <span className="w-5 shrink-0 text-sm font-medium text-muted-foreground">{i + 1}</span>
                    <span className="w-40 shrink-0 truncate text-sm font-medium">{broker.name}</span>
                    <div className="h-2 flex-1 overflow-hidden rounded-full bg-muted">
                      <div
                        className="h-full rounded-full bg-primary"
                        style={{ width: `${(broker.total / max) * 100}%` }}
                      />
                    </div>
                    <span className="w-24 shrink-0 text-right text-sm font-medium">${broker.total.toLocaleString()}</span>
                  </div>
                );
              })}
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

function MiniStat({ label, value }: { label: string; value: number }) {
  return (
    <div>
      <p className="text-lg font-semibold leading-none">{value}</p>
      <p className="mt-0.5 text-[11px] text-muted-foreground">{label}</p>
    </div>
  );
}
