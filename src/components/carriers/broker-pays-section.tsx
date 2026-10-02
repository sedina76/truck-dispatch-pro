import { Button } from "@/components/ui/button";
import { BROKER_PAYS_OPTIONS, brokerPaysOf } from "@/lib/carriers/broker-pays";
import { setCarrierBrokerPays, setCarrierFactorPackageSender } from "@/app/(app)/carriers/broker-pays-actions";

// "Who does the broker pay?" -- decides whether this carrier's loads are
// invoiced to the broker (and settled with the carrier) or billed to the
// carrier on a Dispatch Fee Invoice. Owner/admin can change it.
export function BrokerPaysSection({
  carrierId,
  value,
  canEdit,
  sender,
  canEditSender,
  saved,
  error,
}: {
  carrierId: string;
  value: string | null;
  canEdit: boolean;
  sender: string | null;
  canEditSender: boolean;
  saved?: string;
  error?: string;
}) {
  const current = brokerPaysOf(value);
  return (
    <div className="rounded-md border border-desktop-border bg-card p-4" id="broker-pays">
      <p className="text-[14px] font-semibold">Who does the broker pay?</p>
      <p className="mt-0.5 text-[12.5px] text-muted-foreground">
        Decides how this carrier&apos;s loads are billed. Each load keeps the setting it was dispatched under; changing it also moves open loads (not yet invoiced to the broker, settled or fee-invoiced).
      </p>
      {saved && <p className="mt-2 rounded-sm border border-desktop-success/30 bg-desktop-success/5 px-2.5 py-1.5 text-[12.5px] text-desktop-success">Saved. {saved}</p>}
      {error && <p className="mt-2 rounded-sm border border-danger/30 bg-danger/5 px-2.5 py-1.5 text-[12.5px] text-danger">{error}</p>}
      {canEdit ? (
        <form action={setCarrierBrokerPays.bind(null, carrierId)} className="mt-3 space-y-2">
          {BROKER_PAYS_OPTIONS.map((o) => (
            <label key={o.value} className="flex cursor-pointer items-start gap-2 rounded-sm border border-desktop-border px-3 py-2 text-[13px] has-[:checked]:border-primary has-[:checked]:bg-primary/5">
              <input type="radio" name="broker_pays" value={o.value} defaultChecked={o.value === current} className="mt-0.5" />
              <span>
                <span className="font-medium">{o.label}</span>
                <span className="block text-[12px] text-muted-foreground">{o.help}</span>
              </span>
            </label>
          ))}
          <Button type="submit" size="sm">Save</Button>
        </form>
      ) : (
        <p className="mt-2 text-[13px]">
          <span className="font-medium">{BROKER_PAYS_OPTIONS.find((o) => o.value === current)!.label}</span>
          <span className="block text-[12px] text-muted-foreground">{BROKER_PAYS_OPTIONS.find((o) => o.value === current)!.help} Only an owner or admin can change this.</span>
        </p>
      )}
      {current === "carrier_paid_directly" && (
        <div className="mt-4 border-t border-desktop-border pt-3">
          <p className="text-[13px] font-semibold">Who sends the paperwork to the factor?</p>
          <p className="mt-0.5 text-[12px] text-muted-foreground">
            The carrier&apos;s invoice with the rate confirmation, BOL and POD (Carrier Invoices). If the carrier doesn&apos;t factor, &quot;We send it&quot; goes to the broker.
          </p>
          {canEditSender ? (
            <form action={setCarrierFactorPackageSender.bind(null, carrierId)} className="mt-2 flex flex-wrap items-center gap-3 text-[13px]">
              <label className="flex items-center gap-1.5">
                <input type="radio" name="factor_package_sent_by" value="dispatcher" defaultChecked={sender !== "carrier"} /> We send it for the carrier
              </label>
              <label className="flex items-center gap-1.5">
                <input type="radio" name="factor_package_sent_by" value="carrier" defaultChecked={sender === "carrier"} /> The carrier sends it (we email them the package)
              </label>
              <Button type="submit" size="sm" variant="outline">Save</Button>
            </form>
          ) : (
            <p className="mt-1 text-[13px]">{sender === "carrier" ? "The carrier sends it" : "We send it for the carrier"}</p>
          )}
        </div>
      )}
    </div>
  );
}
