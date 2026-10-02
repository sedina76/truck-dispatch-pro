import Link from "next/link";
import { notFound } from "next/navigation";
import { AlertTriangle, FileText } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { FormField, FormGrid, FormSelect } from "@/components/ui/form-field";
import { StatusBadge } from "@/components/ui/status-badge";
import { Button } from "@/components/ui/button";
import { feeInvoiceActions, feeLineIssues, summarizeFeeLines, type FeeLineCurrent } from "@/lib/dispatch-fee-invoices/summary";
import {
  recordDispatchFeeInvoicePayment,
  removeDispatchFeeInvoiceLine,
  sendDispatchFeeInvoice,
  voidDispatchFeeInvoice,
  voidDispatchFeeInvoicePayment,
} from "../actions";

function money(n: number | string): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
function day(d: string | null): string {
  return d ? new Date(d + "T00:00:00").toLocaleDateString() : "--";
}

type Invoice = {
  id: string;
  invoice_number: string;
  carrier_id: string;
  period_start: string;
  period_end: string;
  status: string;
  total_amount: number;
  amount_paid: number;
  balance_due: number;
  terms_days: number;
  issue_date: string | null;
  due_date: string | null;
  sent_at: string | null;
  paid_at: string | null;
  notes: string | null;
  created_at: string;
  void_reason: string | null;
  voided_at: string | null;
  carriers: { legal_name: string; email: string | null; phone: string | null } | null;
};
type Line = { id: string; line_type: string; description: string; amount: number; service_date: string | null; load_id: string | null; dispatch_id: string | null; load_number: string | null; load_rate: number | null; fee_percentage: number | null; voided: boolean };
type Payment = { id: string; amount: number; method: string; paid_date: string; reference_number: string | null; notes: string | null; status: string; void_reason: string | null };

export default async function DispatchFeeInvoicePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ error?: string }> }) {
  const { id } = await params;
  const { error: actionError } = await searchParams;
  const supabase = await createClient();

  const { data: inv } = await supabase
    .from("carrier_fee_invoices")
    .select("id, invoice_number, carrier_id, period_start, period_end, status, total_amount, amount_paid, balance_due, terms_days, issue_date, due_date, sent_at, paid_at, notes, created_at, void_reason, voided_at, carriers(legal_name, email, phone)")
    .eq("id", id)
    .maybeSingle();
  if (!inv) notFound();
  const invoice = inv as unknown as Invoice;

  const [{ data: linesRaw }, { data: paymentsRaw }] = await Promise.all([
    supabase
      .from("carrier_fee_invoice_lines")
      .select("id, line_type, description, amount, service_date, load_id, dispatch_id, load_number, load_rate, fee_percentage, voided")
      .eq("invoice_id", id)
      .order("sort_order")
      .order("service_date"),
    supabase.from("carrier_fee_invoice_payments").select("id, amount, method, paid_date, reference_number, notes, status, void_reason").eq("invoice_id", id).order("paid_date").order("created_at"),
  ]);
  const lines = (linesRaw ?? []) as Line[];
  const payments = (paymentsRaw ?? []) as Payment[];
  const posted = payments.filter((p) => p.status === "posted");

  // Has anything changed on the billed loads since? (cancelled, or a rate
  // correction after sending -- drafts follow the fee automatically, 0166)
  const dispatchIds = lines.filter((l) => l.line_type === "dispatch_fee" && l.dispatch_id && !l.voided).map((l) => l.dispatch_id as string);
  const current = new Map<string, FeeLineCurrent>();
  if (dispatchIds.length && invoice.status !== "void") {
    const [{ data: dispatchRows }, { data: feeRows }] = await Promise.all([
      supabase.from("dispatches").select("id, status, loads:loads!dispatches_load_id_fkey(status)").in("id", dispatchIds),
      supabase.from("dispatch_financials").select("dispatch_id, dispatch_fee_amount").in("dispatch_id", dispatchIds),
    ]);
    const fees = new Map(((feeRows ?? []) as { dispatch_id: string; dispatch_fee_amount: number }[]).map((f) => [f.dispatch_id, Number(f.dispatch_fee_amount)]));
    for (const d of (dispatchRows ?? []) as unknown as { id: string; status: string; loads: { status: string } | null }[]) {
      if (fees.has(d.id)) current.set(d.id, { fee: fees.get(d.id)!, dispatchStatus: d.status, loadStatus: d.loads?.status ?? null });
    }
  }
  const issues = feeLineIssues(invoice.status, lines, current);
  const issueByLine = new Map(issues.map((i) => [i.lineId, i.message]));
  const isVoid = invoice.status === "void";
  const summary = summarizeFeeLines(lines);
  const can = feeInvoiceActions(invoice.status, Number(invoice.balance_due), posted.length);
  const today = new Date().toISOString().slice(0, 10);
  const overdue = (invoice.status === "sent" || invoice.status === "partially_paid") && invoice.due_date !== null && invoice.due_date < today;
  const pdfHref = `/dispatch-fee-invoices/${id}/pdf`;

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">Dispatch Fee Invoice {invoice.invoice_number}</h1>
          <p className="mt-0.5 text-xs text-muted-foreground">
            {invoice.carriers?.legal_name ?? "--"} -- loads delivered {day(invoice.period_start)} to {day(invoice.period_end)}
            {invoice.carriers?.email ? ` -- ${invoice.carriers.email}` : ""}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <StatusBadge status={invoice.status} />
          <Link href="/dispatch-fee-invoices" className="inline-flex h-8 items-center rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">Back</Link>
          <a href={pdfHref} target="_blank" rel="noopener" className="inline-flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">
            <FileText className="size-4" /> PDF
          </a>
          <a href={`${pdfHref}?download=1`} className="inline-flex h-8 items-center rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">Download</a>
          {can.canSend && (
            <form action={sendDispatchFeeInvoice.bind(null, id)}>
              <Button type="submit" size="sm">Mark as Sent</Button>
            </form>
          )}
        </div>
      </div>

      {actionError && (
        <div className="flex items-start gap-2 rounded-sm border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" /> {actionError}
        </div>
      )}
      {isVoid && (
        <div className="flex items-start gap-2 rounded-sm border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
          Voided{invoice.voided_at ? ` ${new Date(invoice.voided_at).toLocaleDateString()}` : ""}: {invoice.void_reason}. Its loads, advances, fuel and repairs are free to bill again.
        </div>
      )}
      {invoice.status === "draft" && (
        <p className="rounded-sm border border-desktop-border bg-muted/40 px-3 py-2 text-[12px] text-muted-foreground">
          Draft: review the lines and remove anything that shouldn&apos;t be billed. If a load&apos;s rate is corrected, its fee here updates by itself. &quot;Mark as Sent&quot; locks the lines and sets the due date ({invoice.terms_days} days). Send the PDF to the carrier yourself.
        </p>
      )}

      {issues.length > 0 && (
        <div className="space-y-1 rounded-sm border border-warning/30 bg-warning/5 px-3 py-2 text-[12.5px] text-warning">
          <p className="flex items-center gap-1.5 font-semibold"><AlertTriangle className="size-4 shrink-0" /> Loads changed after billing</p>
          {issues.map((i) => <p key={i.lineId}>{i.message}</p>)}
          <p className="text-desktop-text">
            {invoice.status === "draft"
              ? "Remove the cancelled load's line before sending."
              : Number(invoice.amount_paid) > 0
                ? "To correct it: void the payments, void this invoice, then create it again -- the corrected amounts are picked up."
                : "To correct it: void this invoice and create it again -- the corrected amounts are picked up."}
          </p>
        </div>
      )}

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total" value={money(invoice.total_amount)} />
        <DesktopKpiBox label="Paid" value={money(invoice.amount_paid)} tone={Number(invoice.amount_paid) > 0 ? "success" : "neutral"} />
        <DesktopKpiBox label="Balance Due" value={isVoid ? "--" : money(invoice.balance_due)} tone={isVoid ? "neutral" : Number(invoice.balance_due) > 0 ? (overdue ? "danger" : "warning") : "success"} />
        <DesktopKpiBox label={overdue ? "Due (overdue)" : "Due"} value={invoice.due_date ? day(invoice.due_date) : "On send"} tone={overdue ? "danger" : "neutral"} />
      </DesktopKpiStrip>

      <DesktopPanel>
        <DesktopPanelHeader title="What the carrier owes" />
        <DesktopPanelBody className="overflow-auto">
          {lines.length === 0 ? (
            <p className="text-[12.5px] text-muted-foreground">No lines.</p>
          ) : (
            <div className="space-y-4">
              {summary.groups.map((g) => (
                <div key={g.type}>
                  <p className="mb-1 text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">{g.label} ({g.count})</p>
                  <table className="w-full text-[12.5px]">
                    <tbody>
                      {lines.filter((l) => l.line_type === g.type).map((l) => (
                        <tr key={l.id} className={"border-b border-desktop-border last:border-0" + (l.voided ? " text-muted-foreground line-through" : issueByLine.has(l.id) ? " bg-warning/5" : "")} title={issueByLine.get(l.id)}>
                          <td className="w-24 py-1 pr-3 text-muted-foreground">{day(l.service_date)}</td>
                          <td className="py-1 pr-3">
                            {l.load_id ? <Link href={`/loads/${l.load_id}`} className="hover:underline">{l.description}</Link> : l.description}
                          </td>
                          <td className="py-1 pr-3 text-right tabular-nums">{money(l.amount)}</td>
                          <td className="w-16 py-1 text-right">
                            {can.canRemoveLines && (
                              <form action={removeDispatchFeeInvoiceLine.bind(null, id, l.id)}>
                                <button type="submit" className="text-[11px] font-medium text-danger hover:underline">Remove</button>
                              </form>
                            )}
                          </td>
                        </tr>
                      ))}
                      <tr>
                        <td></td>
                        <td className="py-1 pr-3 text-right text-[11.5px] text-muted-foreground">Subtotal</td>
                        <td className="py-1 pr-3 text-right font-medium tabular-nums">{money(g.total)}</td>
                        <td></td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              ))}
              <div className="flex justify-end border-t border-desktop-border pt-2 text-sm font-semibold">
                <span className="mr-6">Total</span>
                <span className="tabular-nums">{money(invoice.total_amount)}</span>
                <span className="w-16"></span>
              </div>
            </div>
          )}
          {invoice.notes && <p className="mt-3 border-t border-desktop-border pt-2 text-[12px] text-muted-foreground">Note: {invoice.notes}</p>}
        </DesktopPanelBody>
      </DesktopPanel>

      {invoice.status !== "draft" && (
        <DesktopPanel>
          <DesktopPanelHeader title="Payments from the carrier" />
          <DesktopPanelBody className="overflow-auto">
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pr-3">Date</th>
                  <th className="py-1.5 pr-3">Method</th>
                  <th className="py-1.5 pr-3">Reference</th>
                  <th className="py-1.5 pr-3 text-right">Amount</th>
                  <th className="py-1.5 pr-3">Status</th>
                  <th className="py-1.5"></th>
                </tr>
              </thead>
              <tbody>
                {payments.map((p) => (
                  <tr key={p.id} className={"border-b border-desktop-border last:border-0" + (p.status === "voided" ? " opacity-50" : "")}>
                    <td className="py-1.5 pr-3">{day(p.paid_date)}</td>
                    <td className="py-1.5 pr-3 capitalize">{p.method.replace(/_/g, " ")}</td>
                    <td className="py-1.5 pr-3">{p.reference_number ?? "--"}</td>
                    <td className={"py-1.5 pr-3 text-right font-medium tabular-nums" + (p.status === "voided" ? " line-through" : "")}>{money(p.amount)}</td>
                    <td className="py-1.5 pr-3">
                      <StatusBadge status={p.status} />
                      {p.status === "voided" && p.void_reason && <p className="mt-0.5 text-[11px] text-muted-foreground">Reason: {p.void_reason}</p>}
                    </td>
                    <td className="py-1.5">
                      {p.status === "posted" && (
                        <details>
                          <summary className="cursor-pointer text-xs font-medium text-danger hover:underline">Void</summary>
                          <form action={voidDispatchFeeInvoicePayment.bind(null, id, p.id)} className="mt-1 flex items-center gap-1.5">
                            <input name="void_reason" placeholder="Reason" required className="h-6 w-40 rounded-sm border border-desktop-border px-1.5 text-[11px]" />
                            <button type="submit" className="text-[11px] font-medium text-danger hover:underline">Confirm</button>
                          </form>
                        </details>
                      )}
                    </td>
                  </tr>
                ))}
                {payments.length === 0 && (
                  <tr><td colSpan={6} className="py-3 text-center text-muted-foreground">No payments recorded yet.</td></tr>
                )}
              </tbody>
            </table>

            {can.canRecordPayment && (
              <form action={recordDispatchFeeInvoicePayment.bind(null, id)} className="mt-3 space-y-3 border-t border-desktop-border pt-3">
                <FormGrid>
                  <FormField label="Amount ($)" name="amount" type="number" step="0.01" defaultValue={Number(invoice.balance_due).toFixed(2)} required />
                  <FormField label="Payment Date" name="paid_date" type="date" defaultValue={today} required />
                  <FormSelect
                    label="Method"
                    name="method"
                    defaultValue="ach"
                    options={[
                      { value: "ach", label: "ACH" },
                      { value: "wire", label: "Wire" },
                      { value: "check", label: "Check" },
                      { value: "credit_card", label: "Card" },
                      { value: "cash", label: "Cash" },
                      { value: "other", label: "Other" },
                    ]}
                  />
                  <FormField label="Reference #" name="reference_number" />
                </FormGrid>
                <p className="text-[11px] text-muted-foreground">Cannot be more than the balance due ({money(invoice.balance_due)}) -- the database refuses it.</p>
                <Button type="submit" size="sm">Record Payment</Button>
              </form>
            )}
          </DesktopPanelBody>
        </DesktopPanel>
      )}

      {can.canVoid && (
        <DesktopPanel>
          <DesktopPanelHeader title="Void Invoice" />
          <DesktopPanelBody>
            <form action={voidDispatchFeeInvoice.bind(null, id)} className="flex items-end gap-2">
              <div className="flex-1">
                <FormField label="Void reason" name="void_reason" placeholder="Required -- its loads and expenses become billable again" required />
              </div>
              <Button type="submit" size="sm" variant="danger">Void</Button>
            </form>
          </DesktopPanelBody>
        </DesktopPanel>
      )}
      {!isVoid && !can.canVoid && (
        <p className="text-[11.5px] text-muted-foreground">To void this invoice, void its payments first.</p>
      )}
    </div>
  );
}
