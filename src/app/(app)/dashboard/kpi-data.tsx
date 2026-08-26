import { DollarSign, Truck as TruckIcon, PackageOpen, UserCheck, Receipt, ShieldAlert, Landmark, AlertTriangle, CreditCard, Siren } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { isActiveLoadStatus } from "@/lib/loads/status";
import { operationalExceptionsTableExists } from "@/lib/exceptions/sync";
import type { KpiTileData, KpiTone } from "@/components/dashboard/kpi-tile";

const SPARKLINE_DAYS = 7;

function startOfDay(d: Date) {
  const copy = new Date(d);
  copy.setHours(0, 0, 0, 0);
  return copy;
}

function dayKey(d: Date) {
  return d.toISOString().slice(0, 10);
}

// Buckets timestamped rows into a fixed-length daily series (oldest -> newest)
// for the sparkline. Real data only: days with no rows are genuinely 0, never
// interpolated or invented.
function bucketDaily(rows: { at: string; amount: number }[], days: number): number[] {
  const buckets = new Map<string, number>();
  const today = startOfDay(new Date());
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(today);
    d.setDate(d.getDate() - i);
    buckets.set(dayKey(d), 0);
  }
  for (const row of rows) {
    const key = dayKey(startOfDay(new Date(row.at)));
    if (buckets.has(key)) buckets.set(key, (buckets.get(key) ?? 0) + row.amount);
  }
  return Array.from(buckets.values());
}

function pctDelta(current: number, previous: number): number | undefined {
  if (previous === 0) return current === 0 ? 0 : undefined;
  return ((current - previous) / previous) * 100;
}

function fmtMoney(n: number) {
  return `$${Math.round(n).toLocaleString()}`;
}

const ACTIVE_DISPATCH_STATUSES = [
  "assigned",
  "accepted",
  "en_route_to_pickup",
  "at_pickup",
  "loaded",
  "en_route_to_delivery",
  "at_delivery",
];

// Phase 2G.9 (item 3): Dashboard is Command Center, open to every role, no
// layout guard -- 5 of these 10 tiles (revenue/AR/collected/profit) are
// financial. Computation is left unchanged (a delicate month-over-month/
// sparkline calculation, not worth risking a subtle break under time
// pressure) -- instead the 5 financial tile ids are filtered out of the
// RETURNED array before this function's result ever reaches the page's
// render tree, for driver/viewer. This mirrors the same "fetch
// server-side, filter before crossing to the client" pattern already
// established and accepted in getDispatchDrawerData().
const FINANCIAL_TILE_IDS = new Set(["revenue-today", "outstanding-invoices", "ar-overdue", "collected-this-month", "profit-month"]);

// Phase 2P.5: Exception Center visibility mirrors operational_exceptions'
// own SELECT policy exactly (owner/admin/dispatcher, 0063) -- passed in by
// the caller (same "compute the boolean once at the page level" pattern
// canSeeFinancials already uses) rather than re-deriving role here.
export async function getDashboardKpis(canSeeFinancials: boolean, canSeeExceptions: boolean = false): Promise<KpiTileData[]> {
  const supabase = await createClient();

  const now = new Date();
  const today = startOfDay(now);
  const yesterday = new Date(today);
  yesterday.setDate(yesterday.getDate() - 1);
  const startOfThisMonth = new Date(today.getFullYear(), today.getMonth(), 1);
  const startOfLastMonth = new Date(today.getFullYear(), today.getMonth() - 1, 1);

  const [
    loadsRes,
    dispatchesRes,
    driversRes,
    trucksRes,
    invoicesRes,
    complianceRes,
    expensesRes,
    advancesRes,
    arSummaryRes,
    postedPaymentsRes,
    loadFinancialsRes,
    dispatchFinancialsRes,
  ] = await Promise.all([
    // Phase 2G.11: `rate` dropped from this select -- 0068's writer
    // cutover (loads/create-actions.ts's create_load_with_stops RPC,
    // loads/actions.ts) stopped populating loads.rate; load_financials is
    // authoritative now, fetched separately below and merged in by id.
    // Same "fetch server-side either way, filter the financial tiles out
    // of the returned array" pattern this file already uses (Phase 2G.9)
    // is kept as-is -- only the SOURCE of the values changes.
    supabase.from("loads").select("id, status, created_at, updated_at"),
    // dispatch_fee_amount dropped for the same reason -- dispatch_financials
    // merged in below.
    supabase.from("dispatches").select("id, status, dispatched_at, driver_id, truck_id"),
    supabase.from("drivers").select("id, status"),
    supabase.from("trucks").select("id, status"),
    supabase.from("invoices").select("status, balance_due, issue_date"),
    supabase.from("compliance_items").select("status"),
    supabase.from("expenses").select("amount, expense_date"),
    supabase.from("dispatch_advances").select("amount, status, updated_at"),
    // Accounts Receivable canonical aggregate -- same function Finance ->
    // Accounts Receivable, the Invoices list KPIs, and Reports all call,
    // so these three tiles can never disagree with those pages.
    supabase.rpc("get_ar_summary").single(),
    supabase.from("payments").select("amount, received_at").eq("status", "posted"),
    supabase.from("load_financials").select("load_id, rate"),
    supabase.from("dispatch_financials").select("dispatch_id, dispatch_fee_amount"),
  ]);

  const loadRateById = new Map((loadFinancialsRes.data ?? []).map((r) => [r.load_id, Number(r.rate)]));
  const dispatchFeeAmountById = new Map((dispatchFinancialsRes.data ?? []).map((r) => [r.dispatch_id, Number(r.dispatch_fee_amount)]));

  const loads = (loadsRes.data ?? []).map((l) => ({ ...l, rate: loadRateById.get(l.id) ?? 0 }));
  const dispatches = (dispatchesRes.data ?? []).map((d) => ({ ...d, dispatch_fee_amount: dispatchFeeAmountById.get(d.id) ?? 0 }));
  const drivers = driversRes.data ?? [];
  const trucks = trucksRes.data ?? [];
  const invoices = invoicesRes.data ?? [];
  const compliance = complianceRes.data ?? [];
  const expenses = expensesRes.data ?? [];
  const advances = advancesRes.data ?? [];
  const arSummary = arSummaryRes.data as {
    total_receivables: number;
    overdue_invoice_count: number;
    overdue_amount: number;
    collected_this_month: number;
  } | null;
  const postedPayments = postedPaymentsRes.data ?? [];

  const sumWhere = <T,>(rows: T[], dateField: keyof T, from: Date, to?: Date, amountField?: keyof T) =>
    rows
      .filter((r) => {
        const d = new Date(r[dateField] as unknown as string);
        return d >= from && (!to || d < to);
      })
      .reduce((sum, r) => sum + (amountField ? Number(r[amountField]) : 1), 0);

  // ---- 1. Revenue Today (booked freight value) ---------------------------
  const revenueToday = sumWhere(loads, "created_at", today, undefined, "rate");
  const revenueYesterday = sumWhere(loads, "created_at", yesterday, today, "rate");
  const revenueSpark = bucketDaily(loads.map((l) => ({ at: l.created_at, amount: Number(l.rate) })), SPARKLINE_DAYS);

  // ---- 2. Active Loads (dispatched and moving, not yet delivered) --------
  const activeLoads = loads.filter((l) => isActiveLoadStatus(l.status));
  const dispatchActivitySpark = bucketDaily(
    dispatches.map((d) => ({ at: d.dispatched_at, amount: 1 })),
    SPARKLINE_DAYS
  );

  // ---- 3. Loads Pending Dispatch (booked, awaiting assignment) ------------
  const pendingDispatchLoads = loads.filter((l) => l.status === "booked");
  const loadsCreatedSpark = bucketDaily(loads.map((l) => ({ at: l.created_at, amount: 1 })), SPARKLINE_DAYS);

  // ---- 4. Available Drivers (active, not on an active dispatch) ----------
  const activeDispatches = dispatches.filter((d) => ACTIVE_DISPATCH_STATUSES.includes(d.status));
  const driverIdsOnDispatch = new Set(activeDispatches.map((d) => d.driver_id).filter(Boolean));
  const truckIdsOnDispatch = new Set(activeDispatches.map((d) => d.truck_id).filter(Boolean));
  const driversAvailable = drivers.filter((d) => d.status === "active" && !driverIdsOnDispatch.has(d.id)).length;

  // ---- 5. Available Trucks (active, not on an active dispatch) -----------
  const trucksAvailable = trucks.filter((t) => t.status === "active" && !truckIdsOnDispatch.has(t.id)).length;

  // ---- 6. Outstanding Invoices (unpaid customer balance) ------------------
  // Sourced from get_ar_summary() (0026_accounts_receivable.sql) -- the
  // same canonical A/R aggregate Finance -> Accounts Receivable uses --
  // instead of a separate in-memory filter, so this can never disagree
  // with that page's Total Receivables figure.
  const outstandingReceivables = Number(arSummary?.total_receivables ?? 0);
  const invoicesIssuedSpark = bucketDaily(invoices.map((i) => ({ at: i.issue_date, amount: 1 })), SPARKLINE_DAYS);

  // ---- 6b. Overdue (canonical, same source as above) ----------------------
  const overdueAmount = Number(arSummary?.overdue_amount ?? 0);
  const overdueInvoiceCount = Number(arSummary?.overdue_invoice_count ?? 0);

  // ---- 6c. Collected This Month (canonical amount; sparkline from real
  // posted-payment activity, status = 'posted' only -- a voided payment
  // was never really collected) --------------------------------------------
  const collectedThisMonth = Number(arSummary?.collected_this_month ?? 0);
  const collectedSpark = bucketDaily(postedPayments.map((p) => ({ at: p.received_at, amount: Number(p.amount) })), SPARKLINE_DAYS);

  // ---- 7. Compliance Alerts (expiring soon or expired) --------------------
  const complianceAlerts = compliance.filter((c) => c.status === "expiring_soon" || c.status === "expired").length;

  // ---- 8. Profit This Month (dispatch fees - expenses - waived advances) --
  const grossThisMonth = sumWhere(dispatches, "dispatched_at", startOfThisMonth, undefined, "dispatch_fee_amount");
  const grossLastMonth = sumWhere(dispatches, "dispatched_at", startOfLastMonth, startOfThisMonth, "dispatch_fee_amount");
  const expensesThisMonth = sumWhere(expenses, "expense_date", startOfThisMonth, undefined, "amount");
  const expensesLastMonth = sumWhere(expenses, "expense_date", startOfLastMonth, startOfThisMonth, "amount");
  const waivedThisMonth = sumWhere(
    advances.filter((a) => a.status === "waived"),
    "updated_at",
    startOfThisMonth,
    undefined,
    "amount"
  );
  const waivedLastMonth = sumWhere(
    advances.filter((a) => a.status === "waived"),
    "updated_at",
    startOfLastMonth,
    startOfThisMonth,
    "amount"
  );
  const netThisMonth = grossThisMonth - expensesThisMonth - waivedThisMonth;
  const netLastMonth = grossLastMonth - expensesLastMonth - waivedLastMonth;
  const feesSpark = bucketDaily(
    dispatches.map((d) => ({ at: d.dispatched_at, amount: Number(d.dispatch_fee_amount) })),
    SPARKLINE_DAYS
  );

  // ---- 9. Open Exceptions (Phase 2P.5 dashboard integration) -------------
  // Reuses the SAME grouped view + role-scoped RLS policy the Exception
  // Center page itself queries (operational_exceptions_grouped, 0063) --
  // no second exception-count implementation. Degrades to omitted (not
  // zero) if the migration isn't live or the role can't see exceptions,
  // matching operationalExceptionsTableExists()'s own graceful-degradation
  // convention rather than a misleading "0".
  let openExceptions: number | null = null;
  let openExceptionsCritical = 0;
  if (canSeeExceptions) {
    const tableExists = await operationalExceptionsTableExists(createServiceRoleClient());
    if (tableExists) {
      const [{ count: activeCount }, { count: criticalCount }] = await Promise.all([
        supabase.from("operational_exceptions_grouped").select("group_key", { count: "exact", head: true }),
        supabase.from("operational_exceptions_grouped").select("group_key", { count: "exact", head: true }).eq("max_severity", "critical"),
      ]);
      openExceptions = activeCount ?? 0;
      openExceptionsCritical = criticalCount ?? 0;
    }
  }

  const updatedAt = now.toISOString();

  const tiles: KpiTileData[] = [
    {
      id: "revenue-today",
      label: "Revenue Today",
      value: fmtMoney(revenueToday),
      icon: <DollarSign className="size-4" />,
      tone: "success",
      href: "/reports/revenue",
      delta: toDelta(pctDelta(revenueToday, revenueYesterday), "vs yesterday"),
      sparkline: revenueSpark,
      tooltip: "Total freight rate on loads booked today.",
      updatedAt,
    },
    {
      id: "active-loads",
      label: "Active Loads",
      value: String(activeLoads.length),
      icon: <TruckIcon className="size-4" />,
      tone: "neutral",
      href: "/dispatch/board",
      sparkline: dispatchActivitySpark,
      tooltip: "Loads currently dispatched or in transit.",
      updatedAt,
    },
    {
      id: "pending-dispatch",
      label: "Loads Pending Dispatch",
      value: String(pendingDispatchLoads.length),
      icon: <PackageOpen className="size-4" />,
      tone: pendingDispatchLoads.length > 0 ? "warning" : "success",
      href: "/dispatch/new",
      sparkline: loadsCreatedSpark,
      tooltip: "Booked loads waiting to be assigned to a carrier, truck, and driver.",
      updatedAt,
    },
    {
      id: "drivers-available",
      label: "Available Drivers",
      value: String(driversAvailable),
      icon: <UserCheck className="size-4" />,
      tone: driversAvailable > 0 ? "success" : "warning",
      href: "/drivers",
      sparkline: dispatchActivitySpark,
      tooltip: "Active drivers not currently assigned to an active dispatch.",
      updatedAt,
    },
    {
      id: "trucks-available",
      label: "Available Trucks",
      value: String(trucksAvailable),
      icon: <TruckIcon className="size-4" />,
      tone: trucksAvailable > 0 ? "success" : "warning",
      href: "/trucks",
      sparkline: dispatchActivitySpark,
      tooltip: "Active trucks not currently assigned to an active dispatch.",
      updatedAt,
    },
    {
      id: "outstanding-invoices",
      label: "Outstanding Invoices",
      value: fmtMoney(outstandingReceivables),
      icon: <Receipt className="size-4" />,
      tone: outstandingReceivables > 0 ? "warning" : "success",
      href: "/accounts-receivable",
      sparkline: invoicesIssuedSpark,
      tooltip: "Total unpaid balance across open (non-paid, non-void) customer invoices.",
      updatedAt,
    },
    {
      id: "ar-overdue",
      label: "Overdue",
      value: fmtMoney(overdueAmount),
      icon: <AlertTriangle className="size-4" />,
      tone: overdueInvoiceCount > 0 ? "danger" : "success",
      href: "/accounts-receivable",
      tooltip: `Outstanding balance on ${overdueInvoiceCount} invoice${overdueInvoiceCount === 1 ? "" : "s"} past due date.`,
      updatedAt,
    },
    {
      id: "collected-this-month",
      label: "Collected This Month",
      value: fmtMoney(collectedThisMonth),
      icon: <CreditCard className="size-4" />,
      tone: "success",
      href: "/payments",
      sparkline: collectedSpark,
      tooltip: "Posted payments received so far this calendar month (voided payments excluded).",
      updatedAt,
    },
    {
      id: "compliance-alerts",
      label: "Compliance Alerts",
      value: String(complianceAlerts),
      icon: <ShieldAlert className="size-4" />,
      tone: complianceAlerts > 0 ? "danger" : "success",
      href: "/compliance",
      tooltip: "Compliance items (CDL, insurance, DOT, permits) expiring soon or already expired.",
      updatedAt,
    },
    // Phase 2P.5 -- Exception Center integration. Omitted entirely (not
    // shown as a misleading "0") when the role can't see exceptions or the
    // migration isn't live -- see openExceptions computation above.
    ...(openExceptions !== null
      ? [
          {
            id: "open-exceptions",
            label: "Open Exceptions",
            value: String(openExceptions),
            icon: <Siren className="size-4" />,
            tone: (openExceptionsCritical > 0 ? "danger" : openExceptions > 0 ? "warning" : "success") as KpiTone,
            href: "/dispatch/exceptions",
            tooltip: "Unresolved operational exceptions (route, detention, GPS, compliance, insurance) across your organization.",
            updatedAt,
          } satisfies KpiTileData,
        ]
      : []),
    {
      id: "profit-month",
      label: "Profit This Month",
      value: fmtMoney(netThisMonth),
      icon: <Landmark className="size-4" />,
      tone: netThisMonth >= 0 ? "success" : "danger",
      href: "/reports/revenue",
      delta: toDelta(pctDelta(netThisMonth, netLastMonth), "vs last month"),
      sparkline: feesSpark,
      tooltip: "Dispatch fees earned this month, minus recorded expenses and waived driver advances.",
      updatedAt,
    },
  ];

  return canSeeFinancials ? tiles : tiles.filter((t) => !FINANCIAL_TILE_IDS.has(t.id));
}

function toDelta(value: number | undefined, label: string): { value: number; label: string } | undefined {
  if (value === undefined) return undefined;
  return { value, label };
}

export type { KpiTileData, KpiTone };
