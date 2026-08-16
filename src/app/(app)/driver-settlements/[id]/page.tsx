import Link from "next/link";
import { notFound } from "next/navigation";
import { FileText, AlertTriangle } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { StatusBadge } from "@/components/ui/status-badge";
import { Button } from "@/components/ui/button";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";
import {
  addSettlementLoad,
  removeSettlementLoad,
  addSettlementAdjustment,
  removeSettlementAdjustment,
  linkMaintenanceRecovery,
  linkFuelRecovery,
  approveDriverSettlement,
  voidDriverSettlement,
  recordDriverSettlementPayment,
  voidDriverSettlementPayment,
} from "../actions";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

export default async function DriverSettlementDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: settlement } = await supabase
    .from("driver_settlements")
    .select(
      "id, settlement_number, driver_id, carrier_id, period_start, period_end, status, gross_pay, adjustments_amount, deductions_amount, advances_amount, net_pay, amount_paid, balance_due, created_at, approved_at, void_reason, drivers(first_name, last_name), carriers(legal_name)"
    )
    .eq("id", id)
    .single();
  if (!settlement) notFound();

  const row = settlement as unknown as {
    id: string;
    settlement_number: string;
    driver_id: string;
    status: string;
    period_start: string;
    period_end: string;
    gross_pay: number;
    adjustments_amount: number;
    deductions_amount: number;
    advances_amount: number;
    net_pay: number;
    amount_paid: number;
    balance_due: number;
    created_at: string;
    approved_at: string | null;
    void_reason: string | null;
    drivers: { first_name: string; last_name: string } | null;
    carriers: { legal_name: string } | null;
  };
  const isDraft = row.status === "draft";
  const canPay = row.status === "approved" || row.status === "partially_paid";

  const [{ data: items }, { data: adjustments }, { data: payments }, { data: eligible }, { data: pendingMaintenance }, { data: pendingFuel }] = await Promise.all([
    supabase.from("driver_settlement_items").select("*").eq("driver_settlement_id", id).order("delivery_date"),
    supabase.from("driver_settlement_adjustments").select("*").eq("driver_settlement_id", id).order("created_at"),
    supabase.from("driver_settlement_payments").select("*").eq("driver_settlement_id", id).order("created_at", { ascending: false }),
    isDraft
      ? supabase.rpc("get_payable_loads", { p_driver_id: row.driver_id, p_period_start: row.period_start, p_period_end: row.period_end })
      : Promise.resolve({ data: [] }),
    // Maintenance charges this SPECIFIC driver was explicitly made
    // responsible for (spec DRIVER RECOVERY / TEAM DRIVER REQUIREMENT --
    // staff chose this driver on the maintenance record itself, never
    // inferred from who drove the truck).
    isDraft
      ? supabase
          .from("maintenance_records")
          .select("id, service_type, service_date, cost, recoverable_amount, recovered_amount, trucks(unit_number), trailers(unit_number)")
          .eq("responsible_driver_id", row.driver_id)
          .eq("recovery_type", "driver_settlement")
          .in("recovery_status", ["pending", "partially_recovered"])
      : Promise.resolve({ data: [] }),
    // Fuel charges this SPECIFIC driver was explicitly made responsible
    // for (spec DRIVER RECOVERY / TEAM DRIVER: staff chose this driver on
    // the fuel log itself, never inferred from who purchased/drove).
    isDraft
      ? supabase
          .from("fuel_logs")
          .select("id, gallons, station_name, purchased_at, total_amount, recoverable_amount, recovered_amount, trucks(unit_number)")
          .eq("responsible_driver_id", row.driver_id)
          .eq("recovery_type", "driver_settlement")
          .in("recovery_status", ["pending", "partially_recovered"])
      : Promise.resolve({ data: [] }),
  ]);

  return (
    <div className="space-y-3">
      <RegisterDesktopActions
        title={`Driver Settlement ${row.settlement_number}`}
        printHref={`/driver-settlements/${id}/pdf`}
        exportOptions={[{ label: "Export PDF", href: `/driver-settlements/${id}/pdf` }]}
        email={{ entityType: "driver_settlement", entityId: id }}
      />
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">{row.settlement_number}</h1>
          <p className="mt-0.5 text-xs text-muted-foreground">
            {row.drivers ? `${row.drivers.first_name} ${row.drivers.last_name}` : "--"} -- {row.carriers?.legal_name ?? "--"} -- {new Date(row.period_start + "T00:00:00").toLocaleDateString()} to {new Date(row.period_end + "T00:00:00").toLocaleDateString()}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <StatusBadge status={row.status} />
          <Link href="/driver-settlements" className="inline-flex h-8 items-center rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">Back</Link>
          <Link href={`/driver-settlements/${id}/pdf`} target="_blank" className="inline-flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">
            <FileText className="size-4" /> Statement
          </Link>
          {isDraft && (
            <form action={approveDriverSettlement.bind(null, id)}>
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

      <DesktopKpiStrip>
        <DesktopKpiBox label="Gross Pay" value={money(row.gross_pay)} />
        <DesktopKpiBox label="Adjustments" value={money(row.adjustments_amount)} />
        <DesktopKpiBox label="Deductions" value={money(row.deductions_amount)} tone="warning" />
        <DesktopKpiBox label="Advances" value={money(row.advances_amount)} tone="warning" />
        <DesktopKpiBox label="Net Pay" value={money(row.net_pay)} tone="primary" />
        <DesktopKpiBox label="Paid" value={money(row.amount_paid)} tone="success" />
        <DesktopKpiBox label="Balance" value={money(row.balance_due)} tone={row.balance_due > 0 ? "warning" : "success"} />
      </DesktopKpiStrip>

      <DesktopPanel>
        <DesktopPanelHeader title="Load Pay Items" />
        <DesktopPanelBody className="overflow-auto">
          <table className="w-full text-[12.5px]">
            <thead>
              <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                <th className="py-1.5 pr-3">Load #</th>
                <th className="py-1.5 pr-3">Delivery Date</th>
                <th className="py-1.5 pr-3 text-right">Miles</th>
                <th className="py-1.5 pr-3 text-right">Load Rate</th>
                <th className="py-1.5 pr-3">Pay Method</th>
                <th className="py-1.5 pr-3 text-right">Pay Rate</th>
                <th className="py-1.5 pr-3 text-right">Gross Pay</th>
                {isDraft && <th className="py-1.5"></th>}
              </tr>
            </thead>
            <tbody>
              {(items ?? []).map((it) => (
                <tr key={it.id} className="border-b border-desktop-border last:border-0">
                  <td className="py-1.5 pr-3 font-medium">
                    <Link href={`/loads/${it.load_id}`} className="text-primary hover:underline">{it.load_number}</Link>
                  </td>
                  <td className="py-1.5 pr-3">{it.delivery_date ? new Date(it.delivery_date + "T00:00:00").toLocaleDateString() : "--"}</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">{it.miles ? Number(it.miles).toLocaleString() : "--"}</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">{money(it.load_rate)}</td>
                  <td className="py-1.5 pr-3 capitalize">{it.pay_method.replace("_", " ")}</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">{it.pay_method === "percentage" ? `${it.pay_rate}%` : money(it.pay_rate)}</td>
                  <td className="py-1.5 pr-3 text-right font-medium tabular-nums">{money(it.gross_pay)}</td>
                  {isDraft && (
                    <td className="py-1.5">
                      <form action={removeSettlementLoad.bind(null, id, it.id)}>
                        <button type="submit" className="text-xs font-medium text-danger hover:underline">Remove</button>
                      </form>
                    </td>
                  )}
                </tr>
              ))}
              {(!items || items.length === 0) && (
                <tr><td colSpan={8} className="py-3 text-center text-muted-foreground">No loads in this settlement.</td></tr>
              )}
            </tbody>
          </table>

          {isDraft && eligible && eligible.length > 0 && (
            <form action={addSettlementLoad.bind(null, id, row.driver_id)} className="mt-3 flex items-end gap-2 border-t border-desktop-border pt-3">
              <div className="flex-1">
                <FormSelect
                  label="Add another eligible load"
                  name="load_id"
                  options={eligible.map((l: { load_id: string; load_number: string; gross_pay: number }) => ({ value: l.load_id, label: `${l.load_number} -- ${money(l.gross_pay)}` }))}
                />
              </div>
              <Button type="submit" size="sm" variant="outline">Add Load</Button>
            </form>
          )}
        </DesktopPanelBody>
      </DesktopPanel>

      <DesktopPanel>
        <DesktopPanelHeader title="Adjustments / Deductions / Advances" />
        <DesktopPanelBody className="overflow-auto">
          <table className="w-full text-[12.5px]">
            <thead>
              <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                <th className="py-1.5 pr-3">Bucket</th>
                <th className="py-1.5 pr-3">Category</th>
                <th className="py-1.5 pr-3">Description</th>
                <th className="py-1.5 pr-3">Date</th>
                <th className="py-1.5 pr-3 text-right">Amount</th>
                {isDraft && <th className="py-1.5"></th>}
              </tr>
            </thead>
            <tbody>
              {(adjustments ?? []).map((a) => (
                <tr key={a.id} className="border-b border-desktop-border last:border-0">
                  <td className="py-1.5 pr-3 capitalize">{a.bucket}</td>
                  <td className="py-1.5 pr-3">{a.category}</td>
                  <td className="py-1.5 pr-3 text-muted-foreground">{a.description ?? "--"}</td>
                  <td className="py-1.5 pr-3">{new Date(a.effective_date + "T00:00:00").toLocaleDateString()}</td>
                  <td className="py-1.5 pr-3 text-right font-medium tabular-nums">{a.bucket === "adjustment" && a.amount >= 0 ? "+" : a.bucket === "adjustment" ? "" : "-"}{money(Math.abs(a.amount))}</td>
                  {isDraft && (
                    <td className="py-1.5">
                      <form action={removeSettlementAdjustment.bind(null, id, a.id)}>
                        <button type="submit" className="text-xs font-medium text-danger hover:underline">Remove</button>
                      </form>
                    </td>
                  )}
                </tr>
              ))}
              {(!adjustments || adjustments.length === 0) && (
                <tr><td colSpan={6} className="py-3 text-center text-muted-foreground">No adjustments, deductions, or advances.</td></tr>
              )}
            </tbody>
          </table>

          {isDraft && (
            <form action={addSettlementAdjustment.bind(null, id)} className="mt-3 space-y-3 border-t border-desktop-border pt-3">
              <FormGrid>
                <FormSelect
                  label="Bucket"
                  name="bucket"
                  required
                  options={[
                    { value: "adjustment", label: "Adjustment (+/-)" },
                    { value: "deduction", label: "Deduction" },
                    { value: "advance", label: "Advance" },
                  ]}
                />
                <FormField label="Category" name="category" placeholder="e.g. Fuel Advance, Tolls, Lumper, Damage" required />
                <FormField label="Amount ($)" name="amount" type="number" step="0.01" required />
                <FormField label="Date" name="effective_date" type="date" defaultValue={new Date().toISOString().slice(0, 10)} required />
                <FormTextarea label="Description / Notes" name="description" />
              </FormGrid>
              <Button type="submit" size="sm" variant="outline">Add</Button>
            </form>
          )}

          {isDraft && pendingMaintenance && pendingMaintenance.length > 0 && (
            <div className="mt-3 border-t border-desktop-border pt-3">
              <p className="mb-1.5 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">Pending Maintenance Recoveries -- Assigned to This Driver</p>
              {(pendingMaintenance as unknown as { id: string; service_type: string; service_date: string; cost: number; recoverable_amount: number; recovered_amount: number; trucks: { unit_number: string } | null; trailers: { unit_number: string } | null }[]).map((m) => {
                const remaining = Number(m.recoverable_amount) - Number(m.recovered_amount);
                return (
                  <form key={m.id} action={linkMaintenanceRecovery.bind(null, id, row.driver_id)} className="mt-1.5 flex flex-wrap items-end gap-2">
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

          {isDraft && pendingFuel && pendingFuel.length > 0 && (
            <div className="mt-3 border-t border-desktop-border pt-3">
              <p className="mb-1.5 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">Pending Fuel Recoveries -- Assigned to This Driver</p>
              {(pendingFuel as unknown as { id: string; gallons: number; station_name: string | null; purchased_at: string; total_amount: number; recoverable_amount: number; recovered_amount: number; trucks: { unit_number: string } | null }[]).map((f) => {
                const remaining = Number(f.recoverable_amount) - Number(f.recovered_amount);
                return (
                  <form key={f.id} action={linkFuelRecovery.bind(null, id, row.driver_id)} className="mt-1.5 flex flex-wrap items-end gap-2">
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
        </DesktopPanelBody>
      </DesktopPanel>

      <DesktopPanel>
        <DesktopPanelHeader title="Payment History" />
        <DesktopPanelBody className="overflow-auto">
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
                  <td className="py-1.5 pr-3 capitalize">{p.method.replace("_", " ")}</td>
                  <td className="py-1.5 pr-3">{p.reference_number ?? "--"}</td>
                  <td className={"py-1.5 pr-3 text-right font-medium tabular-nums" + (p.status === "voided" ? " line-through" : "")}>{money(p.amount)}</td>
                  <td className="py-1.5"><StatusBadge status={p.status} /></td>
                  {canPay && (
                    <td className="py-1.5">
                      {p.status === "posted" && (
                        <details>
                          <summary className="cursor-pointer text-xs font-medium text-danger hover:underline">Void</summary>
                          <form action={voidDriverSettlementPayment.bind(null, id, p.id)} className="mt-1 flex items-center gap-1.5">
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
            <form action={recordDriverSettlementPayment.bind(null, id)} className="mt-3 space-y-3 border-t border-desktop-border pt-3">
              <p className="text-[11px] text-muted-foreground">Balance due: <span className="font-semibold text-desktop-text">{money(row.balance_due)}</span></p>
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
              <Button type="submit" size="sm">Record Driver Payment</Button>
            </form>
          )}
        </DesktopPanelBody>
      </DesktopPanel>

      {row.status !== "void" && (
        <DesktopPanel>
          <DesktopPanelHeader title="Void Settlement" />
          <DesktopPanelBody>
            <form action={voidDriverSettlement.bind(null, id)} className="flex items-end gap-2">
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
