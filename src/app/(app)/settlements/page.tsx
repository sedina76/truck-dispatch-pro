import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopFilterBar, DesktopFilterField, desktopInputClass } from "@/components/desktop/filter-bar";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmptyState } from "@/components/ui/empty-state";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

export default async function CarrierSettlementsPage({
  searchParams,
}: {
  searchParams: Promise<{ carrier_id?: string; status?: string; q?: string }>;
}) {
  const { carrier_id, status, q } = await searchParams;
  const supabase = await createClient();

  const { data: carriers } = await supabase.from("carriers").select("id, legal_name").order("legal_name");

  let query = supabase
    .from("settlements")
    .select(
      "id, settlement_number, carrier_id, period_start, period_end, gross_amount, adjustments_amount, deductions_amount, advances_amount, quick_pay_fee_amount, net_amount, amount_paid, balance_due, status, carriers(legal_name)"
    )
    .order("created_at", { ascending: false });
  if (carrier_id) query = query.eq("carrier_id", carrier_id);
  // "Unpaid Approved" is a derived filter, not a real status value (spec
  // section 42: "Do not invent status values") -- approved/partially_paid
  // rows that still have a balance owed. Every other option maps to a
  // real settlement_status enum value directly.
  if (status === "unpaid_approved") query = query.in("status", ["approved", "partially_paid"]).gt("balance_due", 0);
  else if (status) query = query.eq("status", status);

  const { data: settlementsRaw } = await query;
  // Search by Settlement # OR Carrier name (spec section 41) -- a single
  // .ilike() can't OR across a joined column, so this matches both fields
  // over the already org/status/carrier-filtered result set client-side
  // rather than adding a second round-trip.
  const settlements = q
    ? (settlementsRaw ?? []).filter(
        (r) => r.settlement_number.toLowerCase().includes(q.toLowerCase()) || (r as unknown as { carriers: { legal_name: string } | null }).carriers?.legal_name?.toLowerCase().includes(q.toLowerCase())
      )
    : settlementsRaw;
  const rows = (settlements ?? []) as unknown as {
    id: string;
    settlement_number: string;
    carrier_id: string;
    period_start: string | null;
    period_end: string | null;
    gross_amount: number;
    adjustments_amount: number;
    deductions_amount: number;
    advances_amount: number;
    quick_pay_fee_amount: number;
    net_amount: number;
    amount_paid: number;
    balance_due: number;
    status: string;
    carriers: { legal_name: string } | null;
  }[];

  const totalNet = rows.reduce((sum, r) => sum + Number(r.net_amount), 0);
  const totalOutstanding = rows.filter((r) => r.status !== "void").reduce((sum, r) => sum + Number(r.balance_due), 0);
  const draftCount = rows.filter((r) => r.status === "draft" || r.status === "pending").length;
  const approvedCount = rows.filter((r) => r.status === "approved" || r.status === "partially_paid").length;

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">Carrier Settlements</h1>
          <p className="mt-0.5 text-xs text-muted-foreground">Outside carrier / owner-operator payables -- separate from customer invoicing and company driver pay.</p>
        </div>
        <Link href="/settlements/new" className="inline-flex h-8 items-center rounded-sm bg-primary px-3 text-[13px] font-medium text-primary-foreground hover:bg-primary-hover">
          New Settlement
        </Link>
      </div>

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total Net Pay" value={money(totalNet)} />
        <DesktopKpiBox label="Outstanding Balance" value={money(totalOutstanding)} tone={totalOutstanding > 0 ? "warning" : "success"} />
        <DesktopKpiBox label="Draft" value={draftCount} />
        <DesktopKpiBox label="Approved / Partially Paid" value={approvedCount} tone={approvedCount > 0 ? "warning" : "neutral"} />
      </DesktopKpiStrip>

      <DesktopFilterBar>
        <form method="GET" className="flex flex-wrap items-end gap-2">
          <DesktopFilterField label="Search">
            <input name="q" defaultValue={q ?? ""} placeholder="Settlement # or Carrier..." className={desktopInputClass + " w-52"} />
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
            <select name="status" defaultValue={status ?? ""} className={desktopInputClass + " w-44"}>
              <option value="">All Statuses</option>
              <option value="draft">Draft</option>
              <option value="approved">Approved</option>
              <option value="partially_paid">Partially Paid</option>
              <option value="paid">Paid</option>
              <option value="void">Void</option>
              <option value="unpaid_approved">Unpaid Approved</option>
            </select>
          </DesktopFilterField>
          <button type="submit" className="h-7 rounded-sm bg-primary px-3 text-[12px] font-medium text-primary-foreground hover:bg-primary-hover">Filter</button>
          <Link href="/settlements" className="h-7 rounded-sm border border-desktop-border px-3 text-[12px] font-medium leading-7 hover:bg-muted">Reset</Link>
        </form>
      </DesktopFilterBar>

      <DesktopPanel>
        <DesktopPanelHeader title="Settlements" />
        <DesktopPanelBody className="overflow-auto">
          {rows.length === 0 ? (
            <EmptyState title="No carrier settlements yet" description="Create a settlement to pay a carrier for their completed loads." action={{ label: "New Settlement", href: "/settlements/new" }} />
          ) : (
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pr-3">Settlement #</th>
                  <th className="py-1.5 pr-3">Carrier</th>
                  <th className="py-1.5 pr-3">Period</th>
                  <th className="py-1.5 pr-3 text-right">Gross</th>
                  <th className="py-1.5 pr-3 text-right">Deductions</th>
                  <th className="py-1.5 pr-3 text-right">Advances</th>
                  <th className="py-1.5 pr-3 text-right">Quick Pay</th>
                  <th className="py-1.5 pr-3 text-right">Net</th>
                  <th className="py-1.5 pr-3 text-right">Paid</th>
                  <th className="py-1.5 pr-3 text-right">Balance</th>
                  <th className="py-1.5 pr-3">Status</th>
                  <th className="py-1.5"></th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.id} className="border-b border-desktop-border last:border-0">
                    <td className="py-1.5 pr-3 font-medium">{r.settlement_number}</td>
                    <td className="py-1.5 pr-3">{r.carriers?.legal_name ?? "--"}</td>
                    <td className="py-1.5 pr-3 whitespace-nowrap">
                      {r.period_start ? new Date(r.period_start + "T00:00:00").toLocaleDateString() : "--"} - {r.period_end ? new Date(r.period_end + "T00:00:00").toLocaleDateString() : "--"}
                    </td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.gross_amount)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.deductions_amount)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.advances_amount)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.quick_pay_fee_amount)}</td>
                    <td className="py-1.5 pr-3 text-right font-medium tabular-nums">{money(r.net_amount)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.amount_paid)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.balance_due)}</td>
                    <td className="py-1.5 pr-3"><StatusBadge status={r.status} /></td>
                    <td className="py-1.5">
                      <Link href={`/settlements/${r.id}`} className="text-xs font-medium text-primary hover:underline">View</Link>
                    </td>
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
