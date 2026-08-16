import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { FormField, FormGrid, FormSelect } from "@/components/ui/form-field";
import { Button } from "@/components/ui/button";
import { addDriverPayRate } from "@/app/(app)/driver-settlements/actions";

type PayRateRow = {
  id: string;
  pay_method: string;
  percentage_rate: number | null;
  rate_per_mile: number | null;
  flat_rate: number | null;
  effective_from: string;
  effective_to: string | null;
};

function rateLabel(r: PayRateRow): string {
  if (r.pay_method === "percentage") return `${Number(r.percentage_rate).toFixed(2)}% of load rate`;
  if (r.pay_method === "per_mile") return `$${Number(r.rate_per_mile).toFixed(3)} / mile`;
  return `$${Number(r.flat_rate).toLocaleString(undefined, { minimumFractionDigits: 2 })} flat per load`;
}

// DRIVER PAY (spec section 2): effective-dated pay rules, history preserved
// -- see driver_pay_rates (0031_driver_settlements.sql). Never lets a rate
// change silently affect an already-settled load: driver_settlement_items
// snapshots the rate actually used at settlement time, this table only
// ever feeds calculate_driver_load_pay() for loads not yet settled.
export async function DriverPaySection({ driverId }: { driverId: string }) {
  const supabase = await createClient();
  const { data: rates } = await supabase
    .from("driver_pay_rates")
    .select("id, pay_method, percentage_rate, rate_per_mile, flat_rate, effective_from, effective_to")
    .eq("driver_id", driverId)
    .order("effective_from", { ascending: false });

  const rows = (rates ?? []) as PayRateRow[];
  const current = rows.find((r) => !r.effective_to);

  return (
    <DesktopPanel>
      <DesktopPanelHeader title="Driver Pay" />
      <DesktopPanelBody className="space-y-3">
        <div className="flex items-center justify-between rounded-sm border border-desktop-border bg-desktop-muted px-3 py-2">
          <span className="text-[12.5px] font-medium text-desktop-text">Current Rate</span>
          <span className="text-[13px] font-semibold text-primary">{current ? rateLabel(current) : "Not set"}</span>
        </div>

        {rows.length > 0 && (
          <div className="overflow-x-auto">
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pr-3">Method</th>
                  <th className="py-1.5 pr-3">Rate</th>
                  <th className="py-1.5 pr-3">Effective From</th>
                  <th className="py-1.5">Effective To</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.id} className={"border-b border-desktop-border last:border-0" + (r.effective_to ? " text-muted-foreground" : "")}>
                    <td className="py-1.5 pr-3 capitalize">{r.pay_method.replace("_", " ")}</td>
                    <td className="py-1.5 pr-3 font-medium">{rateLabel(r)}</td>
                    <td className="py-1.5 pr-3">{new Date(r.effective_from + "T00:00:00").toLocaleDateString()}</td>
                    <td className="py-1.5">{r.effective_to ? new Date(r.effective_to + "T00:00:00").toLocaleDateString() : "Current"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        <details className="rounded-sm border border-desktop-border">
          <summary className="cursor-pointer px-3 py-1.5 text-[12px] font-medium text-primary">
            {current ? "Set a new rate (effective going forward)" : "Set pay rate"}
          </summary>
          <div className="border-t border-desktop-border p-3">
            <form action={addDriverPayRate.bind(null, driverId)} className="space-y-3">
              <FormGrid>
                <FormSelect
                  label="Pay Method"
                  name="pay_method"
                  required
                  options={[
                    { value: "percentage", label: "Percentage of Load" },
                    { value: "per_mile", label: "Per Mile" },
                    { value: "flat_rate", label: "Flat Rate per Load" },
                  ]}
                />
                <FormField label="Rate (% for percentage, $ for per-mile/flat)" name="rate_value" type="number" step="0.001" required />
                <FormField label="Effective From" name="effective_from" type="date" defaultValue={new Date().toISOString().slice(0, 10)} required />
              </FormGrid>
              <Button type="submit" size="sm">Save Rate</Button>
            </form>
          </div>
        </details>
      </DesktopPanelBody>
    </DesktopPanel>
  );
}
