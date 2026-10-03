import Link from "next/link";
import { CheckCircle2, Circle } from "lucide-react";
import { Button } from "@/components/ui/button";
import { setCarrierDoesNotFactor } from "@/app/(app)/carriers/broker-pays-actions";

export type FactorStatus = {
  mode: string | null; // carriers.factoring_mode: unconfigured | direct | factored
  factorName: string | null;
  noaApproved: boolean;
  submissionMethod: string | null;
};

// One place that says what a "broker pays the carrier" carrier still needs
// before Carrier Invoices work, each item with its fix right here. Things
// the TMS can fill in itself (invoice code, broker billing links) are done
// automatically and only shown.
export function BillingSetupChecklist({
  carrierId,
  invoiceCode,
  factor,
  sender,
  canEdit,
}: {
  carrierId: string;
  invoiceCode: string | null;
  factor: FactorStatus;
  sender: string | null;
  canEdit: boolean;
}) {
  const factoringDone = factor.mode === "direct" || (factor.mode === "factored" && factor.noaApproved);
  const left = (invoiceCode ? 0 : 1) + (factoringDone ? 0 : 1);
  const ready = left === 0;
  return (
    <div className="rounded-md border border-desktop-border bg-card p-4" id="billing-setup">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-[14px] font-semibold">Billing setup {ready ? <span className="ml-1 text-[12px] font-medium text-desktop-success">-- ready</span> : <span className="ml-1 text-[12px] font-medium text-warning">-- {left} step{left === 1 ? "" : "s"} left</span>}</p>
        {ready && (
          <Link href="/invoices/new" className="text-[12.5px] font-medium text-primary hover:underline">Create Invoice</Link>
        )}
      </div>
      <ul className="mt-2 space-y-2 text-[13px]">
        <Item done label="Broker pays the carrier" note="Invoices -> Create Invoice makes the invoice in the carrier's name. Your fee goes on the Dispatch Fee Invoice." />
        <Item
          done={!!invoiceCode}
          label={invoiceCode ? `Invoice numbers start with ${invoiceCode}` : "Invoice code"}
          note={invoiceCode ? "Set automatically from the carrier's name. You can change it in the carrier form above." : 'Enter a short code in the carrier form above (e.g. "RRT"), or save "Who does the broker pay?" again to fill it in.'}
        />
        <li className="flex items-start gap-2">
          {factoringDone ? <CheckCircle2 className="mt-0.5 size-4 shrink-0 text-desktop-success" /> : <Circle className="mt-0.5 size-4 shrink-0 text-warning" />}
          <div className="flex-1">
            <p className="font-medium">
              {factor.mode === "direct"
                ? "Doesn't factor (the broker pays the carrier itself)"
                : factor.mode === "factored"
                  ? `Factors with ${factor.factorName ?? "its factoring company"}`
                  : "Does this carrier factor?"}
            </p>
            {factor.mode === "factored" && !factor.noaApproved && (
              <p className="text-[12px] text-warning">The notice of assignment isn&apos;t approved yet. Finish it in <Link href="/settings/factoring" className="font-medium underline">Settings, Factoring</Link>.</p>
            )}
            {factor.mode === "factored" && factor.noaApproved && (
              <p className="text-[12px] text-muted-foreground">
                {factor.submissionMethod === "secure_email" ? "Billing packets are emailed to the factor." : "The factor takes uploads on its website: download the billing packet from the invoice."}
              </p>
            )}
            {(!factor.mode || factor.mode === "unconfigured") && (
              <div className="mt-1 flex flex-wrap items-center gap-2">
                {canEdit && (
                  <form action={setCarrierDoesNotFactor.bind(null, carrierId)}>
                    <Button type="submit" size="sm" variant="outline">No, it doesn&apos;t factor</Button>
                  </form>
                )}
                <Link href="/settings/factoring" className="inline-flex h-8 items-center rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">Yes, set up its factoring company</Link>
              </div>
            )}
          </div>
        </li>
        <Item
          done
          label={sender === "carrier" ? "The carrier sends its paperwork (we email them the billing packet)" : "We send the paperwork for the carrier"}
          note="Change it in the box above."
        />
        <Item done label="Brokers" note="Added automatically the first time you invoice a broker for this carrier, using the broker's email and terms. You can edit them below." />
      </ul>
    </div>
  );
}

function Item({ done, label, note }: { done: boolean; label: string; note: string }) {
  return (
    <li className="flex items-start gap-2">
      {done ? <CheckCircle2 className="mt-0.5 size-4 shrink-0 text-desktop-success" /> : <Circle className="mt-0.5 size-4 shrink-0 text-warning" />}
      <div>
        <p className="font-medium">{label}</p>
        <p className="text-[12px] text-muted-foreground">{note}</p>
      </div>
    </li>
  );
}
