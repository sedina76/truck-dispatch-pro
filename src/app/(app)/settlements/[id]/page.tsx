import Link from "next/link";
import { notFound } from "next/navigation";
import { FileText, AlertTriangle } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { DesktopCollapsibleSection, CollapsibleSectionsProvider, CollapsibleSectionsToolbar } from "@/components/desktop/collapsible-section";
import { FormField, FormGrid, FormSelect } from "@/components/ui/form-field";
import { StatusBadge } from "@/components/ui/status-badge";
import { Button } from "@/components/ui/button";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";
import {
  addSettlementLoad,
  removeSettlementLineItem,
  addSettlementAdjustment,
  linkCarrierAdvance,
  linkMaintenanceRecovery,
  linkFuelRecovery,
  setQuickPay,
  setSettlementPayee,
  approveCarrierSettlement,
  voidCarrierSettlement,
  recordCarrierSettlementPayment,
  voidCarrierSettlementPayment,
} from "../actions";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}
function route(pickupCity: string | null, pickupState: string | null, deliveryCity: string | null, deliveryState: string | null): string {
  const pickup = [pickupCity, pickupState].filter(Boolean).join(", ") || "--";
  const delivery = [deliveryCity, deliveryState].filter(Boolean).join(", ") || "--";
  return `${pickup} → ${delivery}`;
}
// Short, stable, non-fabricated display id -- maintenance_records/fuel_logs/
// dispatch_advances have no dedicated number sequence (unlike expenses'
// expense_number), and the spec's migration rule explicitly says not to add
// a schema column purely for display formatting. Same convention already
// used on the Fuel Log Detail page (fuel/[id]/page.tsx) -- not reinvented.
function shortId(prefix: string, id: string): string {
  return `${prefix}-${id.slice(0, 8).toUpperCase()}`;
}

type LineItem = {
  id: string;
  item_type: string;
  description: string;
  amount: number;
  load_id: string | null;
  load_number: string | null;
  delivery_date: string | null;
  customer_revenue: number | null;
  carrier_rate: number | null;
  pickup_city: string | null;
  pickup_state: string | null;
  delivery_city: string | null;
  delivery_state: string | null;
  linked_advance_id: string | null;
  linked_maintenance_id: string | null;
  linked_fuel_log_id: string | null;
  dispatches: { trucks: { unit_number: string } | null; trailers: { unit_number: string } | null; drivers: { first_name: string; last_name: string } | null } | null;
};

export default async function CarrierSettlementDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  // Phase 2G.12: factoring_company_name dropped from the carriers() embed
  // -- carrier_financials is authoritative now, fetched separately below
  // once carrier_id is known. This whole route is already layout-guarded
  // to FINANCIAL_ROLES (settlements/layout.tsx).
  const { data: settlement } = await supabase
    .from("settlements")
    .select(
      "id, settlement_number, carrier_id, period_start, period_end, status, gross_amount, adjustments_amount, deductions_amount, advances_amount, quick_pay_enabled, quick_pay_rate_percent, quick_pay_fee_amount, net_amount, amount_paid, balance_due, created_at, approved_at, void_reason, payee_type, payee_name, carriers(legal_name)"
    )
    .eq("id", id)
    .single();
  if (!settlement) notFound();
  const carrierIdForSettlement = (settlement as unknown as { carrier_id: string }).carrier_id;
  const { data: carrierFinancials } = carrierIdForSettlement
    ? await supabase.from("carrier_financials").select("factoring_company_name").eq("carrier_id", carrierIdForSettlement).maybeSingle()
    : { data: null };

  const row = settlement as unknown as {
    id: string;
    settlement_number: string;
    carrier_id: string;
    status: string;
    period_start: string;
    period_end: string;
    gross_amount: number;
    adjustments_amount: number;
    deductions_amount: number;
    advances_amount: number;
    quick_pay_enabled: boolean;
    quick_pay_rate_percent: number | null;
    quick_pay_fee_amount: number;
    net_amount: number;
    amount_paid: number;
    balance_due: number;
    created_at: string;
    approved_at: string | null;
    void_reason: string | null;
    payee_type: string;
    payee_name: string | null;
    carriers: { legal_name: string } | null;
  };
  const isDraft = row.status === "draft" || row.status === "pending";
  const canPay = row.status === "approved" || row.status === "partially_paid";

  const [{ data: loadItemsRaw }, { data: otherItemsRaw }, { data: payments }, { data: eligible }, { data: availableAdvances }, { data: pendingMaintenance }, { data: pendingFuel }, { data: activity }] = await Promise.all([
    supabase
      .from("settlement_line_items")
      .select("*, dispatches(trucks(unit_number), trailers(unit_number), drivers(first_name, last_name))")
      .eq("settlement_id", id)
      .eq("item_type", "load_pay")
      .order("delivery_date"),
    supabase.from("settlement_line_items").select("*").eq("settlement_id", id).neq("item_type", "load_pay").order("created_at"),
    supabase.from("carrier_settlement_payments").select("*").eq("settlement_id", id).order("created_at", { ascending: false }),
    isDraft
      ? supabase.rpc("get_payable_carrier_loads", { p_carrier_id: row.carrier_id, p_period_start: row.period_start, p_period_end: row.period_end })
      : Promise.resolve({ data: [] }),
    isDraft
      ? supabase.from("dispatch_advances").select("id, amount, description, expense_type").eq("carrier_id", row.carrier_id).eq("status", "pending")
      : Promise.resolve({ data: [] }),
    // Pending maintenance recoveries for this carrier -- recoverable_amount/
    // recovered_amount are the canonical, derived-from-real-settlement-rows
    // totals (0050), never duplicated here.
    isDraft
      ? supabase
          .from("maintenance_records")
          .select("id, service_type, service_date, cost, recoverable_amount, recovered_amount, trucks(unit_number), trailers(unit_number)")
          .eq("carrier_id", row.carrier_id)
          .eq("recovery_type", "carrier_settlement")
          .in("recovery_status", ["pending", "partially_recovered"])
      : Promise.resolve({ data: [] }),
    // Pending fuel recoveries -- same discovery pattern as above (spec:
    // fuel must be discoverable as pending BEFORE any settlement links it).
    isDraft
      ? supabase
          .from("fuel_logs")
          .select("id, gallons, station_name, purchased_at, total_amount, recoverable_amount, recovered_amount, trucks(unit_number)")
          .eq("carrier_id", row.carrier_id)
          .eq("recovery_type", "carrier_settlement")
          .in("recovery_status", ["pending", "partially_recovered"])
      : Promise.resolve({ data: [] }),
    supabase
      .from("activity_logs")
      .select("id, action, created_at, changes, profiles!activity_logs_actor_id_fkey(full_name)")
      .eq("entity_type", "settlement")
      .eq("entity_id", id)
      .order("created_at", { ascending: false })
      .limit(30),
  ]);

  const loadItems = (loadItemsRaw ?? []) as unknown as LineItem[];
  const otherItems = (otherItemsRaw ?? []) as unknown as LineItem[];

  // Itemized traceability (spec section 11): Fuel/Maintenance recoveries and
  // Advances are never folded into a generic "Other Deduction" bucket when
  // linked source data exists -- partitioned here from the SAME already-
  // fetched otherItems, no extra per-row query.
  const fuelLineItems = otherItems.filter((it) => it.linked_fuel_log_id);
  const maintenanceLineItems = otherItems.filter((it) => it.linked_maintenance_id);
  const advanceLineItems = otherItems.filter((it) => it.linked_advance_id);
  const quickPayLineItems = otherItems.filter((it) => it.item_type === "quick_pay_fee");
  const genericItems = otherItems.filter((it) => !it.linked_fuel_log_id && !it.linked_maintenance_id && !it.linked_advance_id && it.item_type !== "quick_pay_fee");

  // Set-based lookups for the two recovery sections' extra display context
  // (Truck/Carrier/Station/Gallons for fuel; Truck-or-Trailer/Vendor for
  // maintenance) -- exactly two queries total regardless of row count
  // (spec section 44: "no N+1... small fixed query set").
  const fuelLogIds = fuelLineItems.map((it) => it.linked_fuel_log_id!).filter(Boolean);
  const maintenanceIds = maintenanceLineItems.map((it) => it.linked_maintenance_id!).filter(Boolean);
  const [{ data: fuelDetailRows }, { data: maintenanceDetailRows }] = await Promise.all([
    fuelLogIds.length > 0
      ? supabase.from("fuel_logs").select("id, gallons, total_amount, recoverable_amount, recovered_amount, station_name, purchased_at, trucks(unit_number), drivers(first_name, last_name), carriers(legal_name)").in("id", fuelLogIds)
      : Promise.resolve({ data: [] }),
    maintenanceIds.length > 0
      ? supabase.from("maintenance_records").select("id, service_type, vendor_name, service_date, cost, recoverable_amount, recovered_amount, trucks(unit_number), trailers(unit_number)").in("id", maintenanceIds)
      : Promise.resolve({ data: [] }),
  ]);
  const fuelDetailMap = new Map((fuelDetailRows ?? []).map((f) => [f.id, f as unknown as { id: string; gallons: number; total_amount: number; recoverable_amount: number; recovered_amount: number; station_name: string | null; purchased_at: string; trucks: { unit_number: string } | null; drivers: { first_name: string; last_name: string } | null; carriers: { legal_name: string } | null }]));
  const maintenanceDetailMap = new Map((maintenanceDetailRows ?? []).map((m) => [m.id, m as unknown as { id: string; service_type: string; vendor_name: string | null; service_date: string; cost: number; recoverable_amount: number; recovered_amount: number; trucks: { unit_number: string } | null; trailers: { unit_number: string } | null }]));

  const totalRevenue = loadItems.reduce((sum, it) => sum + Number(it.customer_revenue ?? 0), 0);
  const grossMargin = totalRevenue - Number(row.gross_amount);
  const marginPercent = totalRevenue > 0 ? (grossMargin / totalRevenue) * 100 : 0;

  // Accounting Reconciliation (spec section 34/59): itemized sums from the
  // real rows above, compared against the canonical DB-generated totals.
  // Never a second calculator -- if these ever disagree, that's a real bug
  // to surface, not something to paper over by trusting the itemized sum.
  const fuelTotal = fuelLineItems.reduce((sum, it) => sum + Number(it.amount), 0);
  const maintenanceTotal = maintenanceLineItems.reduce((sum, it) => sum + Number(it.amount), 0);
  const advanceTotal = advanceLineItems.reduce((sum, it) => sum + Number(it.amount), 0);
  const quickPayTotal = quickPayLineItems.reduce((sum, it) => sum + Number(it.amount), 0);
  const genericAdjustmentTotal = genericItems.filter((it) => it.item_type === "adjustment").reduce((sum, it) => sum + Number(it.amount), 0);
  const genericDeductionTotal = genericItems.filter((it) => it.item_type === "deduction").reduce((sum, it) => sum + Number(it.amount), 0);
  const itemizedDeductionTotal = fuelTotal + maintenanceTotal + genericDeductionTotal;
  const itemizedGross = loadItems.reduce((sum, it) => sum + Number(it.amount), 0);
  const itemizedNet = itemizedGross + genericAdjustmentTotal - itemizedDeductionTotal - advanceTotal - quickPayTotal;
  const reconciliationOk =
    Math.abs(itemizedGross - Number(row.gross_amount)) < 0.01 &&
    Math.abs(genericAdjustmentTotal - Number(row.adjustments_amount)) < 0.01 &&
    Math.abs(itemizedDeductionTotal - Number(row.deductions_amount)) < 0.01 &&
    Math.abs(advanceTotal - Number(row.advances_amount)) < 0.01 &&
    Math.abs(quickPayTotal - Number(row.quick_pay_fee_amount)) < 0.01 &&
    Math.abs(itemizedNet - Number(row.net_amount)) < 0.01;

  const postedPayments = (payments ?? []).filter((p) => p.status === "posted");
  const lastPostedPayment = postedPayments.length > 0 ? postedPayments.reduce((a, b) => (new Date(a.paid_date) > new Date(b.paid_date) ? a : b)) : null;
  const paidDate = row.status === "paid" && lastPostedPayment ? lastPostedPayment.paid_date : null;

  const activityRows = (activity ?? []) as unknown as { id: string; action: string; created_at: string; changes: Record<string, unknown> | null; profiles: { full_name: string } | null }[];

  const sectionDefaults: Record<string, boolean> = {
    summary: true,
    loads: true,
    fuel: true,
    maintenance: true,
    other: true,
    advances: true,
    quickpay: false,
    payments: true,
    reconciliation: false,
    activity: false,
  };

  return (
    <div className="space-y-3">
      <RegisterDesktopActions
        title={`Carrier Settlement ${row.settlement_number}`}
        printHref={`/settlements/${id}/pdf`}
        exportOptions={[{ label: "Export PDF", href: `/settlements/${id}/pdf` }]}
        email={{ entityType: "carrier_settlement", entityId: id }}
      />
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">{row.settlement_number}</h1>
          <p className="mt-0.5 text-xs text-muted-foreground">
            {row.carriers?.legal_name ?? "--"} -- {new Date(row.period_start + "T00:00:00").toLocaleDateString()} to {new Date(row.period_end + "T00:00:00").toLocaleDateString()}
            {row.payee_name && ` -- Payee: ${row.payee_name}`}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <StatusBadge status={row.status} />
          <Link href="/settlements" className="inline-flex h-8 items-center rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">Back</Link>
          <Link href={`/settlements/${id}/pdf`} target="_blank" className="inline-flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">
            <FileText className="size-4" /> Statement
          </Link>
          {isDraft && (
            <form action={approveCarrierSettlement.bind(null, id)}>
              <Button type="submit" size="sm">Approve Settlement</Button>
            </form>
          )}
        </div>
      </div>

      {row.status === "void" && row.void_reason && (
        <div className="flex items-start gap-2 rounded-sm border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
          Voided: {row.void_reason}
        </div>
      )}
      {!reconciliationOk && (
        <div className="flex items-start gap-2 rounded-sm border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
          Itemized line items do not reconcile exactly to the settlement&apos;s canonical totals -- see Accounting Reconciliation below before relying on this statement.
        </div>
      )}

      <CollapsibleSectionsProvider defaults={sectionDefaults}>
        <CollapsibleSectionsToolbar />

        <DesktopCollapsibleSection id="summary" title="Settlement Summary">
          <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-[13px] sm:grid-cols-4">
            <SummaryField label="Created" value={new Date(row.created_at).toLocaleDateString()} />
            <SummaryField label="Approved" value={row.approved_at ? new Date(row.approved_at).toLocaleDateString() : "-- not yet --"} />
            <SummaryField label="Paid" value={paidDate ? new Date(paidDate + "T00:00:00").toLocaleDateString() : "-- not yet --"} />
            <SummaryField label="Status" value={<StatusBadge status={row.status} />} />
          </div>
          <div className="mt-3">
            <DesktopKpiStrip>
              <DesktopKpiBox label="Gross Carrier Pay" value={money(row.gross_amount)} />
              <DesktopKpiBox label="Deductions" value={money(row.deductions_amount)} tone="warning" />
              <DesktopKpiBox label="Advances" value={money(row.advances_amount)} tone="warning" />
              <DesktopKpiBox label="Quick Pay Fee" value={money(row.quick_pay_fee_amount)} tone="warning" />
              <DesktopKpiBox label="Net Carrier Pay" value={money(row.net_amount)} tone="primary" />
              <DesktopKpiBox label="Paid" value={money(row.amount_paid)} tone="success" />
              <DesktopKpiBox label="Balance Due" value={money(row.balance_due)} tone={row.balance_due > 0 ? "warning" : "success"} />
            </DesktopKpiStrip>
          </div>
          <div className="mt-3 rounded-sm border border-desktop-border bg-desktop-muted px-3 py-2">
            <p className="mb-1.5 text-[10px] font-semibold uppercase tracking-wide text-muted-foreground">Internal Revenue -- Staff Only (never shown to the carrier)</p>
            <div className="grid grid-cols-2 gap-x-4 gap-y-1 text-[13px] sm:grid-cols-3">
              <SummaryField label="Customer Revenue" value={money(totalRevenue)} />
              <SummaryField label="Gross Margin" value={`${money(grossMargin)} (${marginPercent.toFixed(1)}%)`} />
              <SummaryField label="Margin %" value={`${marginPercent.toFixed(1)}%`} />
            </div>
          </div>

          {isDraft && (
            <div className="mt-3 border-t border-desktop-border pt-3">
              <p className="mb-1.5 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">Review Before Approval</p>
              <div className="grid grid-cols-2 gap-x-4 gap-y-1 text-[13px] sm:grid-cols-4">
                <SummaryField label="Loads" value={String(loadItems.length)} />
                <SummaryField label="Gross Carrier Pay" value={money(row.gross_amount)} />
                <SummaryField label="Fuel Recoveries" value={money(fuelTotal)} />
                <SummaryField label="Maintenance Recoveries" value={money(maintenanceTotal)} />
                <SummaryField label="Advances" value={money(row.advances_amount)} />
                <SummaryField label="Other Deductions" value={money(genericDeductionTotal)} />
                <SummaryField label="Quick Pay Fee" value={money(row.quick_pay_fee_amount)} />
                <SummaryField label="Net Carrier Pay" value={money(row.net_amount)} strong />
              </div>
              <p className="mt-2 text-[11px] text-muted-foreground">Approving freezes this financial snapshot -- loads, recoveries, advances, and Quick Pay can no longer be added or removed.</p>
            </div>
          )}
        </DesktopCollapsibleSection>

        <DesktopCollapsibleSection id="loads" title="Load Pay" badge={loadItems.length || undefined}>
          <div className="overflow-auto">
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pr-3">Load #</th>
                  <th className="py-1.5 pr-3">Pickup / Delivery</th>
                  <th className="py-1.5 pr-3">Delivery Date</th>
                  <th className="py-1.5 pr-3">Truck</th>
                  <th className="py-1.5 pr-3">Driver</th>
                  <th className="py-1.5 pr-3 text-right">Customer Revenue (Staff Only)</th>
                  <th className="py-1.5 pr-3 text-right">Carrier Pay</th>
                  {isDraft && <th className="py-1.5"></th>}
                </tr>
              </thead>
              <tbody>
                {loadItems.map((it) => (
                  <tr key={it.id} className="border-b border-desktop-border last:border-0">
                    <td className="py-1.5 pr-3 font-medium">
                      <Link href={`/loads/${it.load_id}`} className="text-primary hover:underline">{it.load_number}</Link>
                    </td>
                    <td className="py-1.5 pr-3 text-muted-foreground">{route(it.pickup_city, it.pickup_state, it.delivery_city, it.delivery_state)}</td>
                    <td className="py-1.5 pr-3">{it.delivery_date ? new Date(it.delivery_date + "T00:00:00").toLocaleDateString() : "--"}</td>
                    <td className="py-1.5 pr-3">{it.dispatches?.trucks?.unit_number ?? "--"}{it.dispatches?.trailers?.unit_number ? ` / ${it.dispatches.trailers.unit_number}` : ""}</td>
                    <td className="py-1.5 pr-3">{it.dispatches?.drivers ? `${it.dispatches.drivers.first_name} ${it.dispatches.drivers.last_name}` : "--"}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums text-muted-foreground">{money(it.customer_revenue ?? 0)}</td>
                    <td className="py-1.5 pr-3 text-right font-medium tabular-nums">{money(it.carrier_rate ?? it.amount)}</td>
                    {isDraft && (
                      <td className="py-1.5">
                        <form action={removeSettlementLineItem.bind(null, id, it.id)}>
                          <button type="submit" className="text-xs font-medium text-danger hover:underline">Remove</button>
                        </form>
                      </td>
                    )}
                  </tr>
                ))}
                {loadItems.length === 0 && (
                  <tr><td colSpan={8} className="py-3 text-center text-muted-foreground">No loads in this settlement.</td></tr>
                )}
              </tbody>
            </table>

            {isDraft && eligible && eligible.length > 0 && (
              <form action={addSettlementLoad.bind(null, id, row.carrier_id)} className="mt-3 flex items-end gap-2 border-t border-desktop-border pt-3">
                <div className="flex-1">
                  <FormSelect
                    label="Add another eligible load"
                    name="load_id"
                    options={eligible.map((l: { load_id: string; load_number: string; carrier_rate: number }) => ({ value: l.load_id, label: `${l.load_number} -- ${money(l.carrier_rate)}` }))}
                  />
                </div>
                <Button type="submit" size="sm" variant="outline">Add Load</Button>
              </form>
            )}
          </div>
        </DesktopCollapsibleSection>

        <DesktopCollapsibleSection id="fuel" title="Fuel Recoveries" badge={fuelLineItems.length || undefined}>
          {fuelLineItems.length > 0 ? (
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pr-3">Fuel Log #</th>
                  <th className="py-1.5 pr-3">Truck</th>
                  <th className="py-1.5 pr-3">Station</th>
                  <th className="py-1.5 pr-3">Date</th>
                  <th className="py-1.5 pr-3 text-right">Gallons</th>
                  <th className="py-1.5 pr-3 text-right">Fuel Amount</th>
                  <th className="py-1.5 pr-3 text-right">Recovered in This Settlement</th>
                  {isDraft && <th className="py-1.5"></th>}
                </tr>
              </thead>
              <tbody>
                {fuelLineItems.map((it) => {
                  const detail = fuelDetailMap.get(it.linked_fuel_log_id!);
                  return (
                    <tr key={it.id} className="border-b border-desktop-border last:border-0">
                      <td className="py-1.5 pr-3 font-medium">
                        <Link href={`/fuel/${it.linked_fuel_log_id}`} className="text-primary hover:underline">{shortId("FL", it.linked_fuel_log_id!)}</Link>
                      </td>
                      <td className="py-1.5 pr-3">{detail?.trucks?.unit_number ?? "--"}</td>
                      <td className="py-1.5 pr-3">{detail?.station_name ?? "--"}</td>
                      <td className="py-1.5 pr-3">{detail?.purchased_at ? new Date(detail.purchased_at).toLocaleDateString() : "--"}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums">{detail ? Number(detail.gallons).toFixed(1) : "--"}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums text-muted-foreground">{detail ? money(detail.total_amount) : "--"}</td>
                      <td className="py-1.5 pr-3 text-right font-medium tabular-nums">-{money(it.amount)}</td>
                      {isDraft && (
                        <td className="py-1.5">
                          <form action={removeSettlementLineItem.bind(null, id, it.id)}>
                            <button type="submit" className="text-xs font-medium text-danger hover:underline">Remove</button>
                          </form>
                        </td>
                      )}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          ) : (
            <p className="text-[12.5px] text-muted-foreground">No fuel recoveries in this settlement.</p>
          )}

          {isDraft && pendingFuel && pendingFuel.length > 0 && (
            <div className="mt-3 border-t border-desktop-border pt-3">
              <p className="mb-1.5 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">Pending Fuel Recoveries</p>
              {(pendingFuel as unknown as { id: string; gallons: number; station_name: string | null; purchased_at: string; total_amount: number; recoverable_amount: number; recovered_amount: number; trucks: { unit_number: string } | null }[]).map((f) => {
                const remaining = Number(f.recoverable_amount) - Number(f.recovered_amount);
                return (
                  <form key={f.id} action={linkFuelRecovery.bind(null, id)} className="mt-1.5 flex flex-wrap items-end gap-2">
                    <input type="hidden" name="fuel_log_id" value={f.id} />
                    <p className="text-[12.5px] text-desktop-text">
                      Fuel -- {f.gallons} gal -- {f.trucks?.unit_number ?? "--"} -- {new Date(f.purchased_at).toLocaleDateString()}{f.station_name ? ` -- ${f.station_name}` : ""} -- remaining {money(remaining)}
                    </p>
                    <FormField label="Recover ($)" name="amount" type="number" step="0.01" defaultValue={remaining} />
                    <Button type="submit" size="sm" variant="outline">Link Recovery</Button>
                  </form>
                );
              })}
            </div>
          )}
        </DesktopCollapsibleSection>

        <DesktopCollapsibleSection id="maintenance" title="Maintenance Recoveries" badge={maintenanceLineItems.length || undefined}>
          {maintenanceLineItems.length > 0 ? (
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pr-3">Maintenance #</th>
                  <th className="py-1.5 pr-3">Truck / Trailer</th>
                  <th className="py-1.5 pr-3">Service</th>
                  <th className="py-1.5 pr-3">Vendor</th>
                  <th className="py-1.5 pr-3">Service Date</th>
                  <th className="py-1.5 pr-3 text-right">Repair Cost</th>
                  <th className="py-1.5 pr-3 text-right">Recovered in This Settlement</th>
                  {isDraft && <th className="py-1.5"></th>}
                </tr>
              </thead>
              <tbody>
                {maintenanceLineItems.map((it) => {
                  const detail = maintenanceDetailMap.get(it.linked_maintenance_id!);
                  return (
                    <tr key={it.id} className="border-b border-desktop-border last:border-0">
                      <td className="py-1.5 pr-3 font-medium">
                        <Link href={`/maintenance/${it.linked_maintenance_id}`} className="text-primary hover:underline">{shortId("MNT", it.linked_maintenance_id!)}</Link>
                      </td>
                      <td className="py-1.5 pr-3">{detail?.trucks?.unit_number ?? detail?.trailers?.unit_number ?? "--"}</td>
                      <td className="py-1.5 pr-3">{detail?.service_type ?? "--"}</td>
                      <td className="py-1.5 pr-3">{detail?.vendor_name ?? "--"}</td>
                      <td className="py-1.5 pr-3">{detail?.service_date ? new Date(detail.service_date + "T00:00:00").toLocaleDateString() : "--"}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums text-muted-foreground">{detail ? money(detail.cost) : "--"}</td>
                      <td className="py-1.5 pr-3 text-right font-medium tabular-nums">-{money(it.amount)}</td>
                      {isDraft && (
                        <td className="py-1.5">
                          <form action={removeSettlementLineItem.bind(null, id, it.id)}>
                            <button type="submit" className="text-xs font-medium text-danger hover:underline">Remove</button>
                          </form>
                        </td>
                      )}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          ) : (
            <p className="text-[12.5px] text-muted-foreground">No maintenance recoveries in this settlement.</p>
          )}

          {isDraft && pendingMaintenance && pendingMaintenance.length > 0 && (
            <div className="mt-3 border-t border-desktop-border pt-3">
              <p className="mb-1.5 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">Pending Maintenance Recoveries</p>
              {(pendingMaintenance as unknown as { id: string; service_type: string; service_date: string; cost: number; recoverable_amount: number; recovered_amount: number; trucks: { unit_number: string } | null; trailers: { unit_number: string } | null }[]).map((m) => {
                const remaining = Number(m.recoverable_amount) - Number(m.recovered_amount);
                return (
                  <form key={m.id} action={linkMaintenanceRecovery.bind(null, id)} className="mt-1.5 flex flex-wrap items-end gap-2">
                    <input type="hidden" name="maintenance_id" value={m.id} />
                    <p className="text-[12.5px] text-desktop-text">
                      {m.service_type} -- {m.trucks?.unit_number ?? m.trailers?.unit_number ?? "--"} -- {new Date(m.service_date + "T00:00:00").toLocaleDateString()} -- remaining {money(remaining)}
                    </p>
                    <FormField label="Recover ($)" name="amount" type="number" step="0.01" defaultValue={remaining} />
                    <Button type="submit" size="sm" variant="outline">Link Recovery</Button>
                  </form>
                );
              })}
            </div>
          )}
        </DesktopCollapsibleSection>

        <DesktopCollapsibleSection id="advances" title="Advances" badge={advanceLineItems.length || undefined}>
          {advanceLineItems.length > 0 ? (
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pr-3">Advance #</th>
                  <th className="py-1.5 pr-3">Description</th>
                  <th className="py-1.5 pr-3 text-right">Amount</th>
                  {isDraft && <th className="py-1.5"></th>}
                </tr>
              </thead>
              <tbody>
                {advanceLineItems.map((it) => (
                  <tr key={it.id} className="border-b border-desktop-border last:border-0">
                    <td className="py-1.5 pr-3 font-medium">{shortId("ADV", it.linked_advance_id!)}</td>
                    <td className="py-1.5 pr-3">{it.description}</td>
                    <td className="py-1.5 pr-3 text-right font-medium tabular-nums">-{money(it.amount)}</td>
                    {isDraft && (
                      <td className="py-1.5">
                        <form action={removeSettlementLineItem.bind(null, id, it.id)}>
                          <button type="submit" className="text-xs font-medium text-danger hover:underline">Remove</button>
                        </form>
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <p className="text-[12.5px] text-muted-foreground">No advances in this settlement.</p>
          )}

          {isDraft && availableAdvances && availableAdvances.length > 0 && (
            <form action={linkCarrierAdvance.bind(null, id)} className="mt-3 flex items-end gap-2 border-t border-desktop-border pt-3">
              <div className="flex-1">
                <FormSelect
                  label="Link existing pending advance"
                  name="advance_id"
                  options={availableAdvances.map((a: { id: string; amount: number; description: string | null; expense_type: string }) => ({
                    value: a.id,
                    label: `${a.description || a.expense_type.replace(/_/g, " ")} -- ${money(a.amount)}`,
                  }))}
                />
              </div>
              <Button type="submit" size="sm" variant="outline">Link Advance</Button>
            </form>
          )}
        </DesktopCollapsibleSection>

        <DesktopCollapsibleSection id="other" title="Other Deductions / Adjustments" badge={genericItems.length || undefined}>
          <table className="w-full text-[12.5px]">
            <thead>
              <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                <th className="py-1.5 pr-3">Type</th>
                <th className="py-1.5 pr-3">Description</th>
                <th className="py-1.5 pr-3 text-right">Amount</th>
                {isDraft && <th className="py-1.5"></th>}
              </tr>
            </thead>
            <tbody>
              {genericItems.map((it) => (
                <tr key={it.id} className="border-b border-desktop-border last:border-0">
                  <td className="py-1.5 pr-3 capitalize">{it.item_type.replace(/_/g, " ")}</td>
                  <td className="py-1.5 pr-3">{it.description}</td>
                  <td className="py-1.5 pr-3 text-right font-medium tabular-nums">{it.item_type === "adjustment" && it.amount >= 0 ? "+" : it.item_type === "adjustment" ? "" : "-"}{money(Math.abs(it.amount))}</td>
                  {isDraft && (
                    <td className="py-1.5">
                      <form action={removeSettlementLineItem.bind(null, id, it.id)}>
                        <button type="submit" className="text-xs font-medium text-danger hover:underline">Remove</button>
                      </form>
                    </td>
                  )}
                </tr>
              ))}
              {genericItems.length === 0 && (
                <tr><td colSpan={4} className="py-3 text-center text-muted-foreground">No other adjustments or deductions.</td></tr>
              )}
            </tbody>
          </table>

          {isDraft && (
            <form action={addSettlementAdjustment.bind(null, id)} className="mt-3 flex flex-wrap items-end gap-2 border-t border-desktop-border pt-3">
              <FormSelect
                label="Type"
                name="item_type"
                options={[
                  { value: "adjustment", label: "Adjustment (+/-)" },
                  { value: "deduction", label: "Deduction" },
                  { value: "advance", label: "Advance (manual)" },
                ]}
              />
              <FormField label="Category" name="category" placeholder="e.g. Insurance, Trailer Rent, Cargo Claim" />
              <FormField label="Amount ($)" name="amount" type="number" step="0.01" />
              <Button type="submit" size="sm" variant="outline">Add</Button>
            </form>
          )}

          {isDraft && (
            <div className="mt-3 border-t border-desktop-border pt-3">
              <form action={setSettlementPayee.bind(null, id)} className="flex items-end gap-2">
                <FormSelect
                  label="Pay To"
                  name="payee_type"
                  defaultValue={row.payee_type}
                  options={[
                    { value: "carrier", label: `Carrier -- ${row.carriers?.legal_name ?? ""}` },
                    ...(carrierFinancials?.factoring_company_name ? [{ value: "factor", label: `Factoring Company -- ${carrierFinancials.factoring_company_name}` }] : []),
                  ]}
                />
                <Button type="submit" size="sm" variant="outline">Save</Button>
              </form>
              <p className="mt-1 text-[11px] text-muted-foreground">Snapshotted permanently once this settlement is approved.</p>
            </div>
          )}
        </DesktopCollapsibleSection>

        <DesktopCollapsibleSection id="quickpay" title="Quick Pay">
          {row.quick_pay_enabled ? (
            <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-[13px] sm:grid-cols-4">
              <SummaryField label="Quick Pay Rate" value={`${row.quick_pay_rate_percent}%`} />
              <SummaryField label="Quick Pay Fee" value={money(row.quick_pay_fee_amount)} />
              <SummaryField label="Applied At" value={row.approved_at ? new Date(row.approved_at).toLocaleDateString() : "Draft (not yet frozen)"} />
            </div>
          ) : (
            <p className="text-[12.5px] text-muted-foreground">Not Applied.</p>
          )}
          {isDraft && (
            <form action={setQuickPay.bind(null, id)} className="mt-3 flex items-end gap-3 border-t border-desktop-border pt-3">
              <label className="flex items-center gap-1.5 text-[12.5px]">
                <input type="checkbox" name="quick_pay_enabled" defaultChecked={row.quick_pay_enabled} className="size-3.5" />
                Enable Quick Pay
              </label>
              <FormField label="Rate (%)" name="quick_pay_rate_percent" type="number" step="0.01" defaultValue={row.quick_pay_rate_percent ?? 2} />
              <Button type="submit" size="sm" variant="outline">Apply</Button>
            </form>
          )}
          {!isDraft && (
            <p className="mt-2 text-[11px] text-muted-foreground">Rate and fee are frozen once approved -- never re-read from a current company setting.</p>
          )}
        </DesktopCollapsibleSection>

        <DesktopCollapsibleSection id="payments" title="Payments" badge={payments && payments.length > 0 ? payments.length : undefined}>
          <div className="overflow-auto">
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pr-3">Payment #</th>
                  <th className="py-1.5 pr-3">Date</th>
                  <th className="py-1.5 pr-3">Method</th>
                  <th className="py-1.5 pr-3">Reference</th>
                  <th className="py-1.5 pr-3 text-right">Amount</th>
                  <th className="py-1.5">Status</th>
                  {canPay && <th className="py-1.5"></th>}
                </tr>
              </thead>
              <tbody>
                {(payments ?? []).map((p) => (
                  <tr key={p.id} className={"border-b border-desktop-border last:border-0" + (p.status === "voided" ? " opacity-50" : "")}>
                    <td className="py-1.5 pr-3 font-medium">{p.payment_number}</td>
                    <td className="py-1.5 pr-3">{new Date(p.paid_date + "T00:00:00").toLocaleDateString()}</td>
                    <td className="py-1.5 pr-3 capitalize">{p.method.replace(/_/g, " ")}</td>
                    <td className="py-1.5 pr-3">{p.reference_number ?? "--"}</td>
                    <td className={"py-1.5 pr-3 text-right font-medium tabular-nums" + (p.status === "voided" ? " line-through" : "")}>{money(p.amount)}</td>
                    <td className="py-1.5">
                      <StatusBadge status={p.status} />
                      {p.status === "voided" && p.void_reason && <p className="mt-0.5 text-[11px] text-muted-foreground">Reason: {p.void_reason}</p>}
                    </td>
                    {canPay && (
                      <td className="py-1.5">
                        {p.status === "posted" && (
                          <details>
                            <summary className="cursor-pointer text-xs font-medium text-danger hover:underline">Void</summary>
                            <form action={voidCarrierSettlementPayment.bind(null, id, p.id)} className="mt-1 flex items-center gap-1.5">
                              <input name="void_reason" placeholder="Reason" required className="h-6 w-40 rounded-sm border border-desktop-border px-1.5 text-[11px]" />
                              <button type="submit" className="text-[11px] font-medium text-danger hover:underline">Confirm</button>
                            </form>
                          </details>
                        )}
                      </td>
                    )}
                  </tr>
                ))}
                {(!payments || payments.length === 0) && (
                  <tr><td colSpan={7} className="py-3 text-center text-muted-foreground">No payments recorded yet.</td></tr>
                )}
              </tbody>
            </table>

            {canPay && row.balance_due > 0 && (
              <form action={recordCarrierSettlementPayment.bind(null, id)} className="mt-3 space-y-3 border-t border-desktop-border pt-3">
                <div className="grid grid-cols-2 gap-x-4 gap-y-1 text-[12.5px] sm:grid-cols-4">
                  <SummaryField label="Net Carrier Pay" value={money(row.net_amount)} />
                  <SummaryField label="Previously Paid" value={money(row.amount_paid)} />
                  <SummaryField label="Balance Due" value={money(row.balance_due)} strong />
                </div>
                <FormGrid>
                  <FormField label="Amount ($)" name="amount" type="number" step="0.01" defaultValue={Number(row.balance_due)} required />
                  <FormField label="Payment Date" name="paid_date" type="date" defaultValue={new Date().toISOString().slice(0, 10)} required />
                  <FormSelect
                    label="Method"
                    name="method"
                    defaultValue="ach"
                    options={[
                      { value: "ach", label: "ACH" },
                      { value: "wire", label: "Wire" },
                      { value: "check", label: "Check" },
                      { value: "cash", label: "Cash" },
                      { value: "other", label: "Other" },
                    ]}
                  />
                  <FormField label="Reference #" name="reference_number" />
                  <FormField label="Check #" name="check_number" />
                  <FormField label="Bank Reference" name="bank_reference" />
                </FormGrid>
                <p className="text-[11px] text-muted-foreground">Cannot exceed the current balance due -- enforced by the database regardless of what&apos;s submitted.</p>
                <Button type="submit" size="sm">Record Carrier Payment</Button>
              </form>
            )}
          </div>
        </DesktopCollapsibleSection>

        <DesktopCollapsibleSection id="reconciliation" title="Accounting Reconciliation">
          <div className="max-w-md space-y-1 text-[13px]">
            <ReconRow label="Gross Carrier Pay" value={row.gross_amount} itemized={itemizedGross} />
            <ReconRow label="+ Adjustments" value={row.adjustments_amount} itemized={genericAdjustmentTotal} />
            <ReconRow label="- Fuel Recoveries" value={fuelTotal} itemized={fuelTotal} />
            <ReconRow label="- Maintenance Recoveries" value={maintenanceTotal} itemized={maintenanceTotal} />
            <ReconRow label="- Other Deductions" value={genericDeductionTotal} itemized={genericDeductionTotal} />
            <ReconRow label="- Advances" value={row.advances_amount} itemized={advanceTotal} />
            <ReconRow label="- Quick Pay Fee" value={row.quick_pay_fee_amount} itemized={quickPayTotal} />
            <div className="flex items-center justify-between border-t border-desktop-border pt-1.5 font-semibold">
              <span>= Net Carrier Pay</span>
              <span className={reconciliationOk ? "" : "text-danger"}>{money(row.net_amount)}{!reconciliationOk && ` (itemized: ${money(itemizedNet)})`}</span>
            </div>
            <div className="mt-2 flex items-center justify-between border-t border-desktop-border pt-1.5">
              <span>Net Carrier Pay</span>
              <span>{money(row.net_amount)}</span>
            </div>
            <div className="flex items-center justify-between">
              <span>- Posted Payments</span>
              <span>{money(row.amount_paid)}</span>
            </div>
            <div className="flex items-center justify-between border-t border-desktop-border pt-1.5 font-semibold">
              <span>= Balance Due</span>
              <span>{money(row.balance_due)}</span>
            </div>
          </div>
          <p className={`mt-3 text-[11.5px] ${reconciliationOk ? "text-desktop-success" : "text-danger"}`}>
            {reconciliationOk ? "Itemized line items reconcile exactly to the canonical settlement totals." : "WARNING: itemized totals do not match the canonical database totals exactly -- do not rely on this statement until resolved."}
          </p>
        </DesktopCollapsibleSection>

        <DesktopCollapsibleSection id="activity" title="Activity History">
          {activityRows.length === 0 ? (
            <p className="text-[12.5px] text-muted-foreground">No activity recorded yet.</p>
          ) : (
            <div className="space-y-2">
              {activityRows.map((a) => (
                <div key={a.id} className="flex items-center justify-between rounded-sm border border-desktop-border bg-desktop-panel px-3 py-2 text-[12.5px]">
                  <div>
                    <p className="font-medium text-desktop-text">{a.action.replace(/_/g, " ")}</p>
                    <p className="text-muted-foreground">by {a.profiles?.full_name ?? "Unknown"}</p>
                  </div>
                  <span className="text-[11px] text-muted-foreground">{new Date(a.created_at).toLocaleString()}</span>
                </div>
              ))}
            </div>
          )}
        </DesktopCollapsibleSection>
      </CollapsibleSectionsProvider>

      {row.status !== "void" && (
        <DesktopPanel>
          <DesktopPanelHeader title="Void Settlement" />
          <DesktopPanelBody>
            <form action={voidCarrierSettlement.bind(null, id)} className="flex items-end gap-2">
              <div className="flex-1">
                <FormField label="Void Reason" name="void_reason" placeholder="Required" required />
              </div>
              <Button type="submit" size="sm" variant="danger">Void</Button>
            </form>
          </DesktopPanelBody>
        </DesktopPanel>
      )}
    </div>
  );
}

function SummaryField({ label, value, strong }: { label: string; value: React.ReactNode; strong?: boolean }) {
  return (
    <div>
      <p className="text-[10.5px] font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={`capitalize text-desktop-text ${strong ? "font-semibold text-primary" : ""}`}>{value}</p>
    </div>
  );
}

function ReconRow({ label, value, itemized }: { label: string; value: number; itemized: number }) {
  const mismatch = Math.abs(value - itemized) > 0.01;
  return (
    <div className="flex items-center justify-between">
      <span className="text-muted-foreground">{label}</span>
      <span className={mismatch ? "font-medium text-danger" : ""}>{money(value)}</span>
    </div>
  );
}
