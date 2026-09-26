"use client";

import { useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter, DialogClose } from "@/components/ui/dialog";
import { createCarrierInvoiceDraft, listBillableLoads, previewCarrierInvoiceIssuance, type BillableCarrier, type BillableLoad } from "@/app/(app)/carrier-invoices/issuance-actions";
import { issuanceConfirmationLines, issuanceMessage, newWorkflowKey, tryBegin, type IssuancePreview } from "@/lib/factoring/carrier-invoice-issuance";

// Step 1 of the controlled issuance workflow: choose ONE carrier, select ITS delivered loads, preview what the server resolved (billing mode, factor/routing/terms or direct billing, recipient, totals and the
// SEPARATE dispatch fee), then create a DRAFT after an explicit confirmation. Nothing here chooses a relationship, factor, routing, organization or total; the server does, and re-validates everything.
export function NewCarrierInvoiceForm({ carriers }: { carriers: BillableCarrier[] }) {
  const router = useRouter();
  const [carrierId, setCarrierId] = useState("");
  const [loads, setLoads] = useState<BillableLoad[]>([]);
  const [selected, setSelected] = useState<string[]>([]);
  const [preview, setPreview] = useState<IssuancePreview | null>(null);
  const [error, setError] = useState<{ code: string; message: string } | null>(null);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [pending, startTransition] = useTransition();
  const keyRef = useRef("");
  const guard = useRef({ inFlight: false });

  const chosen = loads.filter((l) => selected.includes(l.id));
  // recipient = the broker (or customer) every selected load shares; a mixed selection is refused here AND by the database
  const brokerIds = new Set(chosen.map((l) => l.brokerId));
  const customerIds = new Set(chosen.map((l) => l.customerId));
  let recipient: { type: "broker" | "customer"; id: string } | null = null;
  if (chosen.length > 0 && brokerIds.size === 1 && chosen[0].brokerId) recipient = { type: "broker", id: chosen[0].brokerId };
  else if (chosen.length > 0 && customerIds.size === 1 && chosen[0].customerId) recipient = { type: "customer", id: chosen[0].customerId };
  const mixed = chosen.length > 0 && !recipient;

  function pickCarrier(id: string) {
    setCarrierId(id);
    setSelected([]);
    setPreview(null);
    setError(null);
    setLoads([]);
    if (id) startTransition(async () => setLoads(await listBillableLoads(id)));
  }

  function toggle(id: string) {
    setPreview(null);
    setSelected((cur) => (cur.includes(id) ? cur.filter((x) => x !== id) : [...cur, id]));
  }

  async function runPreview() {
    if (!recipient) return;
    setBusy(true);
    setError(null);
    try {
      const p = await previewCarrierInvoiceIssuance({ carrierId, loadIds: selected, recipientType: recipient.type, recipientId: recipient.id });
      setPreview(p);
      if (!(p.success === true && p.eligible === true)) setError({ code: String(p.code ?? "UNKNOWN"), message: issuanceMessage(p) });
    } finally {
      setBusy(false);
    }
  }

  async function confirm() {
    if (!recipient || !tryBegin(guard.current)) return; // ignore duplicate clicks while a request is running
    setBusy(true);
    setError(null);
    try {
      const outcome = await createCarrierInvoiceDraft({ carrierId, loadIds: selected, recipientType: recipient.type, recipientId: recipient.id }, keyRef.current);
      if (outcome.ok) {
        setOpen(false);
        router.push(`/carrier-invoices/${outcome.invoiceId}`); // the draft page shows the next step (ready for issue)
      } else {
        setError({ code: outcome.code, message: outcome.error });
      }
    } finally {
      guard.current.inFlight = false;
      setBusy(false);
    }
  }

  const eligible = preview?.success === true && preview?.eligible === true;
  return (
    <div className="space-y-4">
      <div>
        <label htmlFor="ci-carrier" className="block text-sm font-medium">
          Carrier
        </label>
        <select id="ci-carrier" className="mt-1 w-full rounded-md border p-2 text-sm" value={carrierId} onChange={(e) => pickCarrier(e.target.value)}>
          <option value="">Select a carrier...</option>
          {carriers.map((c) => (
            <option key={c.id} value={c.id}>
              {c.name}
            </option>
          ))}
        </select>
        <p className="mt-1 text-xs text-muted-foreground">One invoice is for one carrier only. Carriers, brokers and organizations are never mixed.</p>
      </div>

      {carrierId ? (
        <fieldset className="rounded-md border p-3" aria-busy={pending}>
          <legend className="px-1 text-sm font-medium">Delivered loads of this carrier</legend>
          {pending ? <p className="text-sm text-muted-foreground">Loading...</p> : null}
          {!pending && loads.length === 0 ? <p className="text-sm text-muted-foreground">No delivered loads found for this carrier.</p> : null}
          <ul className="space-y-1 text-sm">
            {loads.map((l) => (
              <li key={l.id}>
                <label className="flex items-center gap-2">
                  <input type="checkbox" checked={selected.includes(l.id)} onChange={() => toggle(l.id)} />
                  <span>
                    {l.loadNumber} <span className="text-muted-foreground">({l.status})</span>
                  </span>
                </label>
              </li>
            ))}
          </ul>
          {mixed ? (
            <p role="alert" className="mt-2 text-sm text-red-700">
              The selected loads belong to different brokers/customers. Select loads of ONE broker (or customer).
            </p>
          ) : null}
        </fieldset>
      ) : null}

      <Button type="button" onClick={runPreview} disabled={busy || !recipient || selected.length === 0}>
        {busy ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : null}
        Preview invoice
      </Button>

      {error && !open ? (
        <p role="alert" data-testid="issuance-refusal" className="rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-800">
          <span className="font-mono text-xs">({error.code})</span> {error.message}
        </p>
      ) : null}

      {eligible && preview ? (
        <section aria-labelledby="ci-preview" className="space-y-3 rounded-md border p-4">
          <h2 id="ci-preview" className="text-base font-semibold">
            What the server resolved
          </h2>
          <dl className="grid grid-cols-[auto,1fr] gap-x-4 gap-y-1 text-sm" data-testid="issuance-preview">
            {issuanceConfirmationLines(preview).map((l) => (
              <div key={l.label} className="contents">
                <dt className="text-muted-foreground">{l.label}</dt>
                <dd className="font-medium">{l.value}</dd>
              </div>
            ))}
          </dl>
          <Dialog
            open={open}
            onOpenChange={(next) => {
              if (busy) return;
              if (next) {
                keyRef.current = newWorkflowKey();
                setError(null);
              }
              setOpen(next);
            }}
          >
            <Button type="button" onClick={() => { keyRef.current = newWorkflowKey(); setError(null); setOpen(true); }}>
              Create draft invoice
            </Button>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>Confirm draft carrier invoice</DialogTitle>
                <DialogDescription>
                  A DRAFT is created from the selected loads. Nothing is issued or sent to a factor yet: you will mark it ready and issue it as separate, deliberate steps. The billing mode, factor and routing are selected by the system.
                </DialogDescription>
              </DialogHeader>
              <dl className="grid grid-cols-[auto,1fr] gap-x-4 gap-y-1 text-sm" data-testid="issuance-confirmation">
                {issuanceConfirmationLines(preview).map((l) => (
                  <div key={l.label} className="contents">
                    <dt className="text-muted-foreground">{l.label}</dt>
                    <dd className="font-medium">{l.value}</dd>
                  </div>
                ))}
              </dl>
              {error ? (
                <p role="alert" className="text-sm text-red-700">
                  <span className="font-mono text-xs">({error.code})</span> {error.message}
                </p>
              ) : null}
              <DialogFooter>
                <DialogClose asChild>
                  <Button type="button" variant="outline" disabled={busy}>
                    Cancel
                  </Button>
                </DialogClose>
                <Button type="button" onClick={confirm} disabled={busy} aria-busy={busy}>
                  {busy ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : null}
                  Confirm and create draft
                </Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>
        </section>
      ) : null}
    </div>
  );
}
