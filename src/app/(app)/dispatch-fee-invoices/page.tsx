import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopFilterBar, DesktopFilterField, desktopInputClass } from "@/components/desktop/filter-bar";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmptyState } from "@/components/ui/empty-state";
import { BillingSubnav } from "@/components/desktop/billing-subnav";

function money(n: number | string): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
function day(d: string | null): string {
  return d ? new Date(d + "T00:00:00").toLocaleDateString() : "--";
}

type Row = {
  id: string;
  invoice_number: string;
  carrier_id: string;
  period_start: string;
  period_end: string;
  status: string;
  total_amount: number;
  amount_paid: number;
  balance_due: number;
  due_date: string | null;
  carriers: { legal_name: string } | null;
};

export default async function DispatchFeeInvoicesPage({
  searchParams,
}: {
  searchParams: Promise<{ carrier_id?: string; status?: string; q?: string }>;
}) {
  const { carrier_id, status, q } = await searchParams;
  const supabase = await createClient();

  const { data: carriers } = await supabase.from("carriers").select("id, legal_name").order("legal_name");

  let query = supabase
    .from("carrier_fee_invoices")
    .select("id, invoice_number, carrier_id, period_start, period_end, status, total_amount, amount_paid, balance_due, due_date, carriers(legal_name)")
    .order("created_at", { ascending: false })
    .limit(500);
  if (carrier_id) query = query.eq("carrier_id", carrier_id);
  if (status === "open") query = query.in("status", ["sent", "partially_paid"]);
  else if (status) query = query.eq("status", status);
  const { data, error } = await query;

  const needle = (q ?? "").trim().toLowerCase();
  const rows = ((data ?? []) as unknown as Row[]).filter(
    (r) => !needle || r.invoice_number.toLowerCase().includes(needle) || (r.carriers?.legal_name ?? "").toLowerCase().includes(needle)
  );

  const today = new Date().toISOString().slice(0, 10);
  const open = rows.filter((r) => r.status === "sent" || r.status === "partially_paid");
  const outstanding = open.reduce((s, r) => s + Number(r.balance_due), 0);
  const overdue = open.filter((r) => r.due_date && r.due_date < today).length;
  const drafts = rows.filter((r) => r.status === "draft").length;
  const collected = rows.filter((r) => r.status !== "void").reduce((s, r) => s + Number(r.amount_paid), 0);

  return (
    <div className="space-y-3">
      <BillingSubnav />
      <div className="flex items-center justify-between gap-3">
        <div>
          <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">Dispatch Fee Invoices</h1>
          <p className="mt-0.5 text-xs text-muted-foreground">
            What carriers owe you: the dispatch fee on each delivered load, plus advances, fuel and repairs you paid for them. One invoice per carrier per period.
          </p>
        </div>
        <Link href="/dispatch-fee-invoices/new" className="inline-flex h-8 shrink-0 items-center rounded-sm bg-primary px-3 text-[13px] font-medium text-primary-foreground hover:bg-primary-hover">
          New Invoice
        </Link>
      </div>

      <DesktopKpiStrip>
        <DesktopKpiBox label="Outstanding" value={money(outstanding)} tone={outstanding > 0 ? "warning" : "success"} />
        <DesktopKpiBox label="Overdue" value={overdue} tone={overdue > 0 ? "danger" : "neutral"} />
        <DesktopKpiBox label="Drafts" value={drafts} />
        <DesktopKpiBox label="Collected" value={money(collected)} />
      </DesktopKpiStrip>

      <DesktopFilterBar>
        <form method="GET" className="flex flex-wrap items-end gap-2">
          <DesktopFilterField label="Search">
            <input name="q" defaultValue={q ?? ""} placeholder="Invoice # or carrier..." className={desktopInputClass + " w-52"} />
          </DesktopFilterField>
          <DesktopFilterField label="Carrier">
            <select name="carrier_id" defaultValue={carrier_id ?? ""} className={desktopInputClass + " w-52"}>
              <option value="">All Carriers</option>
              {(carriers ?? []).map((c) => (
                <option key={c.id} value={c.id}>{c.legal_name}</option>
              ))}
            </select>
          </DesktopFilterField>
          <DesktopFilterField label="Status">
            <select name="status" defaultValue={status ?? ""} className={desktopInputClass + " w-40"}>
              <option value="">All Statuses</option>
              <option value="open">Open (unpaid)</option>
              <option value="draft">Draft</option>
              <option value="sent">Sent</option>
              <option value="partially_paid">Partially Paid</option>
              <option value="paid">Paid</option>
              <option value="void">Void</option>
            </select>
          </DesktopFilterField>
          <button type="submit" className="h-7 rounded-sm bg-primary px-3 text-[12px] font-medium text-primary-foreground hover:bg-primary-hover">Filter</button>
          <Link href="/dispatch-fee-invoices" className="h-7 rounded-sm border border-desktop-border px-3 text-[12px] font-medium leading-7 hover:bg-muted">Reset</Link>
        </form>
      </DesktopFilterBar>

      <DesktopPanel>
        <DesktopPanelHeader title="Invoices" />
        <DesktopPanelBody className="overflow-auto">
          {error ? (
            <p className="text-sm text-danger">Could not load invoices: {error.message}</p>
          ) : rows.length === 0 ? (
            <EmptyState
              title="No dispatch fee invoices yet"
              description="Pick a carrier and period to bill your dispatch fees and anything you paid on their behalf."
              action={{ label: "New Invoice", href: "/dispatch-fee-invoices/new" }}
            />
          ) : (
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pr-3">Invoice #</th>
                  <th className="py-1.5 pr-3">Carrier</th>
                  <th className="py-1.5 pr-3">Period</th>
                  <th className="py-1.5 pr-3">Due</th>
                  <th className="py-1.5 pr-3 text-right">Total</th>
                  <th className="py-1.5 pr-3 text-right">Paid</th>
                  <th className="py-1.5 pr-3 text-right">Balance</th>
                  <th className="py-1.5 pr-3">Status</th>
                  <th className="py-1.5"></th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => {
                  const late = (r.status === "sent" || r.status === "partially_paid") && r.due_date && r.due_date < today;
                  return (
                    <tr key={r.id} className={"border-b border-desktop-border last:border-0" + (r.status === "void" ? " opacity-60" : "")}>
                      <td className="py-1.5 pr-3 font-medium">{r.invoice_number}</td>
                      <td className="py-1.5 pr-3">{r.carriers?.legal_name ?? "--"}</td>
                      <td className="whitespace-nowrap py-1.5 pr-3">{day(r.period_start)} - {day(r.period_end)}</td>
                      <td className={"whitespace-nowrap py-1.5 pr-3" + (late ? " font-medium text-danger" : "")}>{day(r.due_date)}{late ? " (overdue)" : ""}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.total_amount)}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.amount_paid)}</td>
                      <td className="py-1.5 pr-3 text-right font-medium tabular-nums">{r.status === "void" ? "--" : money(r.balance_due)}</td>
                      <td className="py-1.5 pr-3"><StatusBadge status={r.status} /></td>
                      <td className="py-1.5">
                        <Link href={`/dispatch-fee-invoices/${r.id}`} className="text-xs font-medium text-primary hover:underline">View</Link>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
        </DesktopPanelBody>
      </DesktopPanel>
    </div>
  );
}
