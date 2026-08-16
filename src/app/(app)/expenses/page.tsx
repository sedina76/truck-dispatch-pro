import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopFilterBar, DesktopFilterField, desktopInputClass } from "@/components/desktop/filter-bar";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { PageHeader } from "@/components/ui/page-header";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmptyState } from "@/components/ui/empty-state";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

type SearchParams = {
  start?: string;
  end?: string;
  scope?: string;
  category?: string;
  status?: string;
  load_id?: string;
  truck_id?: string;
  driver_id?: string;
  carrier_id?: string;
  q?: string;
};

export default async function ExpensesPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const { start, end, scope, category, status, load_id, truck_id, driver_id, carrier_id, q } = await searchParams;
  const supabase = await createClient();

  const [{ data: summary }, { data: trucks }, { data: drivers }, { data: carriers }] = await Promise.all([
    supabase.rpc("get_expense_summary", { p_period_start: start || null, p_period_end: end || null }).single(),
    supabase.from("trucks").select("id, unit_number").order("unit_number"),
    supabase.from("drivers").select("id, first_name, last_name").order("last_name"),
    supabase.from("carriers").select("id, legal_name").order("legal_name"),
  ]);

  let query = supabase
    .from("expenses")
    .select(
      "id, expense_number, expense_date, scope, category, vendor_name, amount, tax_amount, total_amount, status, receipt_document_id, recorded_by, reference_number, load_id, truck_id, driver_id, carrier_id, loads(load_number), trucks(unit_number), profiles!expenses_recorded_by_fkey(full_name)"
    )
    .order("expense_date", { ascending: false });
  if (start) query = query.gte("expense_date", start);
  if (end) query = query.lte("expense_date", end);
  if (scope) query = query.eq("scope", scope);
  if (category) query = query.eq("category", category);
  if (status) query = query.eq("status", status);
  if (load_id) query = query.eq("load_id", load_id);
  if (truck_id) query = query.eq("truck_id", truck_id);
  if (driver_id) query = query.eq("driver_id", driver_id);
  if (carrier_id) query = query.eq("carrier_id", carrier_id);
  if (q) query = query.or(`expense_number.ilike.%${q}%,vendor_name.ilike.%${q}%,reference_number.ilike.%${q}%`);

  const { data } = await query;
  const rows = (data ?? []) as unknown as {
    id: string;
    expense_number: string;
    expense_date: string;
    scope: string;
    category: string;
    vendor_name: string | null;
    amount: number;
    total_amount: number;
    status: string;
    receipt_document_id: string | null;
    load_id: string | null;
    truck_id: string | null;
    loads: { load_number: string } | null;
    trucks: { unit_number: string } | null;
    profiles: { full_name: string } | null;
  }[];

  const s = summary as {
    total_count: number;
    total_amount: number;
    direct_load_total: number;
    truck_fleet_total: number;
    general_overhead_total: number;
    pending_count: number;
    pending_amount: number;
  } | null;

  const filterQs = () => {
    const p = new URLSearchParams();
    for (const [k, v] of Object.entries({ start, end, scope, category, status, load_id, truck_id, driver_id, carrier_id, q })) if (v) p.set(k, v);
    return p.toString();
  };

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Expenses", href: "/expenses" }]} />
      <RegisterDesktopActions title="Expenses" exportOptions={[{ label: "Export CSV (Filtered)", href: `/expenses/export?${filterQs()}` }]} />
      <PageHeader title="Expenses" description="Direct load costs, fleet/truck costs, and general overhead in one place." primaryAction={{ label: "Add Expense", href: "/expenses/new" }} />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total Expenses" value={money(s?.total_amount ?? 0)} />
        <DesktopKpiBox label="Direct Load Costs" value={money(s?.direct_load_total ?? 0)} />
        <DesktopKpiBox label="Truck / Fleet Costs" value={money(s?.truck_fleet_total ?? 0)} />
        <DesktopKpiBox label="General Overhead" value={money(s?.general_overhead_total ?? 0)} />
        <DesktopKpiBox label="Unapproved" value={`${s?.pending_count ?? 0} (${money(s?.pending_amount ?? 0)})`} tone={s && s.pending_count > 0 ? "warning" : "neutral"} href="/expenses?status=draft" />
      </DesktopKpiStrip>

      <DesktopFilterBar>
        <form className="flex flex-wrap items-end gap-2" action="/expenses">
          <DesktopFilterField label="Search">
            <input type="text" name="q" defaultValue={q} placeholder="Expense #, vendor, reference..." className={desktopInputClass} />
          </DesktopFilterField>
          <DesktopFilterField label="From">
            <input type="date" name="start" defaultValue={start} className={desktopInputClass} />
          </DesktopFilterField>
          <DesktopFilterField label="To">
            <input type="date" name="end" defaultValue={end} className={desktopInputClass} />
          </DesktopFilterField>
          <DesktopFilterField label="Scope">
            <select name="scope" defaultValue={scope ?? ""} className={desktopInputClass}>
              <option value="">All</option>
              <option value="load">Load</option>
              <option value="truck">Truck</option>
              <option value="driver">Driver</option>
              <option value="carrier">Carrier</option>
              <option value="general">General</option>
            </select>
          </DesktopFilterField>
          <DesktopFilterField label="Status">
            <select name="status" defaultValue={status ?? ""} className={desktopInputClass}>
              <option value="">All</option>
              <option value="draft">Draft</option>
              <option value="submitted">Submitted</option>
              <option value="approved">Approved</option>
              <option value="paid">Paid</option>
              <option value="void">Void</option>
            </select>
          </DesktopFilterField>
          <DesktopFilterField label="Truck">
            <select name="truck_id" defaultValue={truck_id ?? ""} className={desktopInputClass}>
              <option value="">All</option>
              {(trucks ?? []).map((t) => <option key={t.id} value={t.id}>{t.unit_number}</option>)}
            </select>
          </DesktopFilterField>
          <DesktopFilterField label="Driver">
            <select name="driver_id" defaultValue={driver_id ?? ""} className={desktopInputClass}>
              <option value="">All</option>
              {(drivers ?? []).map((d) => <option key={d.id} value={d.id}>{d.first_name} {d.last_name}</option>)}
            </select>
          </DesktopFilterField>
          <DesktopFilterField label="Carrier">
            <select name="carrier_id" defaultValue={carrier_id ?? ""} className={desktopInputClass}>
              <option value="">All</option>
              {(carriers ?? []).map((c) => <option key={c.id} value={c.id}>{c.legal_name}</option>)}
            </select>
          </DesktopFilterField>
          <button type="submit" className="h-7 rounded-sm bg-primary px-3 text-[12px] font-medium text-primary-foreground hover:bg-primary-hover">
            Apply
          </button>
          {(start || end || scope || category || status || load_id || truck_id || driver_id || carrier_id || q) && (
            <Link href="/expenses" className="flex h-7 items-center rounded-sm px-2 text-[12px] font-medium text-muted-foreground hover:bg-desktop-muted">
              Clear
            </Link>
          )}
        </form>
      </DesktopFilterBar>

      <DesktopPanel>
        <DesktopPanelHeader title={`Expenses (${rows.length})`} />
        <DesktopPanelBody className="overflow-auto p-0">
          {rows.length === 0 ? (
            <div className="p-4"><EmptyState title="No expenses match" description="Adjust filters or add a new expense." action={{ label: "Add Expense", href: "/expenses/new" }} /></div>
          ) : (
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pl-3 pr-3">Expense #</th>
                  <th className="py-1.5 pr-3">Date</th>
                  <th className="py-1.5 pr-3">Scope</th>
                  <th className="py-1.5 pr-3">Category</th>
                  <th className="py-1.5 pr-3">Load</th>
                  <th className="py-1.5 pr-3">Truck</th>
                  <th className="py-1.5 pr-3">Vendor</th>
                  <th className="py-1.5 pr-3 text-right">Amount</th>
                  <th className="py-1.5 pr-3">Status</th>
                  <th className="py-1.5 pr-3">Receipt</th>
                  <th className="py-1.5 pr-3">Created By</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.id} className="border-b border-desktop-border last:border-0 hover:bg-desktop-muted/50">
                    <td className="py-1.5 pl-3 pr-3 font-medium">
                      <Link href={`/expenses/${r.id}`} className="text-primary hover:underline">{r.expense_number}</Link>
                    </td>
                    <td className="py-1.5 pr-3 text-muted-foreground">{new Date(r.expense_date + "T00:00:00").toLocaleDateString()}</td>
                    <td className="py-1.5 pr-3 capitalize">{r.scope}</td>
                    <td className="py-1.5 pr-3 capitalize">{r.category.replace(/_/g, " ")}</td>
                    <td className="py-1.5 pr-3">
                      {r.loads ? <Link href={`/loads/${r.load_id}`} className="text-primary hover:underline">{r.loads.load_number}</Link> : "--"}
                    </td>
                    <td className="py-1.5 pr-3">{r.trucks?.unit_number ?? "--"}</td>
                    <td className="py-1.5 pr-3">{r.vendor_name ?? "--"}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums font-medium">{money(r.total_amount)}</td>
                    <td className="py-1.5 pr-3"><StatusBadge status={r.status} /></td>
                    <td className="py-1.5 pr-3">{r.receipt_document_id ? "Yes" : "--"}</td>
                    <td className="py-1.5 pr-3 text-muted-foreground">{r.profiles?.full_name ?? "--"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </DesktopPanelBody>
      </DesktopPanel>
    </div>
  );
}
