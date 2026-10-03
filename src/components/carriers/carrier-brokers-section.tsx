import { Button } from "@/components/ui/button";
import { StatusBadge } from "@/components/ui/status-badge";
import { saveCarrierBroker } from "@/app/(app)/carriers/broker-pays-actions";

export type CarrierBrokerRow = { broker_id: string; broker_name: string; status: string; billing_email: string | null; payment_terms_days: number | null; factoring_eligible: boolean };

// Where this carrier's own invoices go, per broker (carrier_brokers, 0131).
// A carrier invoice to a broker can only be issued once that broker is
// listed here as active. Shown for "broker pays the carrier" carriers.
export function CarrierBrokersSection({
  carrierId,
  rows,
  brokers,
  canEdit,
}: {
  carrierId: string;
  rows: CarrierBrokerRow[];
  brokers: { id: string; name: string; email: string | null }[];
  canEdit: boolean;
}) {
  const inputClass = "h-8 rounded-sm border border-desktop-border bg-background px-2 text-[13px]";
  return (
    <div className="rounded-md border border-desktop-border bg-card p-4" id="carrier-brokers">
      <p className="text-[14px] font-semibold">Brokers this carrier invoices</p>
      <p className="mt-0.5 text-[12.5px] text-muted-foreground">
        Needed before a Carrier Invoice to that broker can be issued: the broker&apos;s billing email and terms for this carrier, and whether the carrier&apos;s factor buys invoices on that broker.
      </p>
      {rows.length > 0 && (
        <table className="mt-3 w-full text-[12.5px]">
          <thead>
            <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
              <th className="py-1.5 pr-3">Broker</th>
              <th className="py-1.5 pr-3">Billing email</th>
              <th className="py-1.5 pr-3">Terms</th>
              <th className="py-1.5 pr-3">Factor buys</th>
              <th className="py-1.5">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.broker_id} className="border-b border-desktop-border last:border-0">
                <td className="py-1.5 pr-3 font-medium">{r.broker_name}</td>
                <td className="py-1.5 pr-3">{r.billing_email ?? "--"}</td>
                <td className="py-1.5 pr-3">{r.payment_terms_days != null ? `${r.payment_terms_days} days` : "--"}</td>
                <td className="py-1.5 pr-3">{r.factoring_eligible ? "Yes" : "No"}</td>
                <td className="py-1.5"><StatusBadge status={r.status} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {canEdit && (
        <form action={saveCarrierBroker.bind(null, carrierId)} className="mt-3 flex flex-wrap items-end gap-2 border-t border-desktop-border pt-3 text-[12px]">
          <label className="flex flex-col gap-0.5">
            Broker
            <select name="broker_id" required defaultValue="" className={inputClass + " w-52"}>
              <option value="" disabled>Select a broker...</option>
              {brokers.map((b) => (
                <option key={b.id} value={b.id}>{b.name}</option>
              ))}
            </select>
          </label>
          <label className="flex flex-col gap-0.5">
            Billing email
            <input name="billing_email" type="email" required placeholder="ap@broker.com" className={inputClass + " w-52"} />
          </label>
          <label className="flex flex-col gap-0.5">
            Terms (days)
            <input name="payment_terms_days" type="number" min={0} max={365} step={1} defaultValue={30} required className={inputClass + " w-24"} />
          </label>
          <label className="flex h-8 items-center gap-1.5">
            <input type="checkbox" name="factoring_eligible" defaultChecked /> Factor buys invoices on this broker
          </label>
          <Button type="submit" size="sm">Save and activate</Button>
          <span className="w-full text-[11px] text-muted-foreground">Saving an existing broker updates its details.</span>
        </form>
      )}
    </div>
  );
}
