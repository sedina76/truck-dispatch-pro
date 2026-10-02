import Link from "next/link";
import { AlertTriangle } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopFilterField, desktopInputClass } from "@/components/desktop/filter-bar";
import { Button } from "@/components/ui/button";
import { defaultFeePeriod, feePeriodError, summarizeFeeLines } from "@/lib/dispatch-fee-invoices/summary";
import { brokerPaysOf } from "@/lib/carriers/broker-pays";
import { createDispatchFeeInvoice } from "../actions";

function money(n: number | string): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

type PreviewLine = { line_type: string; description: string; amount: number; service_date: string | null; load_number: string | null };

// Step 1: pick carrier + period (GET, so the preview is just a page load).
// Step 2: the preview is exactly what create_carrier_fee_invoice will bill
// (same database query); "Create Draft Invoice" saves it as a draft you
// can still trim before sending.
export default async function NewDispatchFeeInvoicePage({
  searchParams,
}: {
  searchParams: Promise<{ carrier_id?: string; period_start?: string; period_end?: string; error?: string }>;
}) {
  const sp = await searchParams;
  const supabase = await createClient();
  const { data: carriers } = await supabase.from("carriers").select("id, legal_name, load_proceeds_model").eq("is_active", true).order("legal_name");

  const fallback = defaultFeePeriod();
  const carrierId = sp.carrier_id ?? "";
  const start = sp.period_start || fallback.start;
  const end = sp.period_end || fallback.end;
  const periodError = carrierId ? feePeriodError(start, end) : null;

  let preview: PreviewLine[] = [];
  let previewError: string | null = periodError;
  if (carrierId && !periodError) {
    const { data, error } = await supabase.rpc("preview_carrier_fee_invoice", { p_carrier_id: carrierId, p_period_start: start, p_period_end: end });
    if (error) previewError = error.message;
    else preview = (data ?? []) as PreviewLine[];
  }
  const summary = summarizeFeeLines(preview);
  const carrier = (carriers ?? []).find((c) => c.id === carrierId);
  const carrierName = carrier?.legal_name;
  const brokerPaysUs = !!carrier && brokerPaysOf(carrier.load_proceeds_model) === "dispatcher_receives_funds";

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">New Dispatch Fee Invoice</h1>
          <p className="mt-0.5 text-xs text-muted-foreground">
            Bills a carrier for your dispatch fee on each load delivered in the period, plus advances, fuel and repairs you paid for them that haven&apos;t been billed or deducted yet.
          </p>
        </div>
        <Link href="/dispatch-fee-invoices" className="inline-flex h-8 items-center rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">Back</Link>
      </div>

      {sp.error && (
        <div className="flex items-start gap-2 rounded-sm border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" /> {sp.error}
        </div>
      )}

      <DesktopPanel>
        <DesktopPanelHeader title="1. Carrier and period" />
        <DesktopPanelBody>
          <form method="GET" className="flex flex-wrap items-end gap-2">
            <DesktopFilterField label="Carrier">
              <select name="carrier_id" defaultValue={carrierId} required className={desktopInputClass + " w-60"}>
                <option value="" disabled>Select a carrier...</option>
                {(carriers ?? []).map((c) => (
                  <option key={c.id} value={c.id}>{c.legal_name}{brokerPaysOf(c.load_proceeds_model) === "dispatcher_receives_funds" ? " (broker pays us)" : ""}</option>
                ))}
              </select>
            </DesktopFilterField>
            <DesktopFilterField label="Delivered from">
              <input type="date" name="period_start" defaultValue={start} required className={desktopInputClass + " w-36"} />
            </DesktopFilterField>
            <DesktopFilterField label="Delivered to">
              <input type="date" name="period_end" defaultValue={end} required className={desktopInputClass + " w-36"} />
            </DesktopFilterField>
            <button type="submit" className="h-7 rounded-sm bg-primary px-3 text-[12px] font-medium text-primary-foreground hover:bg-primary-hover">Preview</button>
          </form>
        </DesktopPanelBody>
      </DesktopPanel>

      {carrierId && (
        <DesktopPanel>
          <DesktopPanelHeader title={`2. Review${carrierName ? ` -- ${carrierName}` : ""}`} />
          <DesktopPanelBody>
            {brokerPaysUs && (
              <p className="mb-3 rounded-sm border border-desktop-border bg-muted/40 px-3 py-2 text-[12px] text-muted-foreground">
                This carrier is set to &quot;Broker pays us&quot;, so its load fees are not billed here (you keep them from the broker&apos;s payment and settle with the carrier). Only advances, fuel and repairs can be billed.{" "}
                <Link href={`/carriers/${carrierId}#broker-pays`} className="font-medium text-primary hover:underline">Change who the broker pays</Link>
              </p>
            )}
            {previewError ? (
              <p className="text-sm text-danger">{previewError}</p>
            ) : preview.length === 0 ? (
              <p className="text-[12.5px] text-muted-foreground">
                Nothing to bill this carrier for that period: no delivered loads with a dispatch fee, and no advances, fuel or repairs left to bill. Loads count by their delivery date; loads already on a carrier settlement or another invoice are not billed again.
              </p>
            ) : (
              <div className="space-y-4">
                {summary.groups.map((g) => (
                  <div key={g.type}>
                    <p className="mb-1 text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">{g.label} ({g.count})</p>
                    <table className="w-full text-[12.5px]">
                      <tbody>
                        {preview.filter((l) => l.line_type === g.type).map((l, i) => (
                          <tr key={i} className="border-b border-desktop-border last:border-0">
                            <td className="w-24 py-1 pr-3 text-muted-foreground">{l.service_date ? new Date(l.service_date + "T00:00:00").toLocaleDateString() : "--"}</td>
                            <td className="py-1 pr-3">{l.description}</td>
                            <td className="py-1 text-right tabular-nums">{money(l.amount)}</td>
                          </tr>
                        ))}
                        <tr>
                          <td></td>
                          <td className="py-1 pr-3 text-right text-[11.5px] text-muted-foreground">Subtotal</td>
                          <td className="py-1 text-right font-medium tabular-nums">{money(g.total)}</td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                ))}
                <div className="flex justify-end border-t border-desktop-border pt-2 text-sm font-semibold">
                  <span className="mr-6">Total the carrier owes</span>
                  <span className="tabular-nums">{money(summary.total)}</span>
                </div>

                <form action={createDispatchFeeInvoice} className="space-y-2 border-t border-desktop-border pt-3">
                  <input type="hidden" name="carrier_id" value={carrierId} />
                  <input type="hidden" name="period_start" value={start} />
                  <input type="hidden" name="period_end" value={end} />
                  <label className="block text-[11px] font-medium text-muted-foreground">
                    Note on the invoice (optional)
                    <textarea name="notes" rows={2} maxLength={1000} className="mt-1 block w-full rounded-sm border border-desktop-border bg-background px-2 py-1 text-[13px]" />
                  </label>
                  <div className="flex items-center gap-3">
                    <Button type="submit" size="sm">Create Draft Invoice</Button>
                    <span className="text-[11px] text-muted-foreground">Saved as a draft: you can remove lines before sending. Nothing is sent to the carrier yet.</span>
                  </div>
                </form>
              </div>
            )}
          </DesktopPanelBody>
        </DesktopPanel>
      )}
    </div>
  );
}
