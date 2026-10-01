"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2, HandCoins } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter, DialogClose } from "@/components/ui/dialog";
import { submitCarrierInvoiceToFactor } from "@/app/(app)/carrier-invoices/factoring-actions";
import { confirmationLines, newIdempotencyKey, panelStateFor, tryBeginSubmit, type FactoringPreview } from "@/lib/factoring/carrier-invoice-submission";
import { driftSentence } from "@/lib/factoring/carrier-invoice-issuance";

// "Submit to factoring" for ONE carrier invoice. There is deliberately NO factor / relationship picker: the destination shown is what the server resolved (the carrier's active
// default) and can only be confirmed or cancelled. The submit is disabled while in flight (state + ref guard), one idempotency key is used per confirmation, and the RPC's own
// code/message is shown verbatim.
export function CarrierInvoiceFactoringPanel({ carrierInvoiceId, preview }: { carrierInvoiceId: string; preview: FactoringPreview | null }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<{ code: string; message: string } | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const keyRef = useRef<string>("");
  const guard = useRef({ inFlight: false });

  const state = panelStateFor(preview);
  if (state.kind === "hidden") return null;
  if (state.kind === "reissue_required") {
    // D-57c / D-57d: drift (or a direct-billing / uncontrolled issuance) REFUSES submission. There is no submit control here; the only path is the controlled reissue workflow below on this page.
    return (
      <div role="alert" data-testid="factoring-reissue-required" className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
        <span className="font-medium">Reissue required before factoring</span> <span className="font-mono text-xs">({state.code})</span>: {state.message}{" "}
        {state.dimensions.length > 0 ? driftSentence(state.dimensions) : null}{" "}
        <a href="#reissue" className="underline">
          Go to the controlled reissue workflow
        </a>
        .
      </div>
    );
  }
  if (state.kind === "blocked") {
    return (
      <div role="status" data-testid="factoring-blocked" className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
        <span className="font-medium">Factoring unavailable</span> <span className="font-mono text-xs">({state.code})</span>: {state.message}
      </div>
    );
  }

  async function confirm() {
    if (!tryBeginSubmit(guard.current)) return; // ignore duplicate clicks while a submission is running
    setBusy(true);
    setError(null);
    try {
      const outcome = await submitCarrierInvoiceToFactor(carrierInvoiceId, keyRef.current);
      if (outcome.ok) {
        setDone(outcome.replay ? "This invoice was already submitted with this request." : "The invoice was submitted to the carrier's factor.");
        setOpen(false);
        router.refresh(); // reload the invoice + factoring state from the server
      } else {
        setError({ code: outcome.code, message: outcome.error });
      }
    } catch {
      // Network drop, deploy, or maintenance window: say so instead of failing silently.
      setError({ code: "TRANSPORT", message: "We couldn't reach the server. Check your connection, then refresh to see whether it went through before trying again." });
    } finally {
      guard.current.inFlight = false;
      setBusy(false);
    }
  }

  return (
    <section aria-labelledby="factoring-heading" className="rounded-md border p-4">
      <h2 id="factoring-heading" className="flex items-center gap-2 text-base font-semibold">
        <HandCoins className="h-4 w-4" /> Factoring
      </h2>
      {done ? (
        <p role="status" className="mt-2 text-sm text-green-700">
          {done}
        </p>
      ) : (
        <Dialog
          open={open}
          onOpenChange={(next) => {
            if (busy) return;
            if (next) {
              keyRef.current = newIdempotencyKey();
              setError(null);
            }
            setOpen(next);
          }}
        >
          <Button type="button" className="mt-2" onClick={() => { keyRef.current = newIdempotencyKey(); setError(null); setOpen(true); }}>
            Submit to factoring
          </Button>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Confirm factoring submission</DialogTitle>
              <DialogDescription>
                This invoice will be submitted to the carrier&apos;s active default factor shown below. The destination is selected by the system and cannot be changed here.
              </DialogDescription>
            </DialogHeader>
            <dl className="grid grid-cols-[auto,1fr] gap-x-4 gap-y-1 text-sm" data-testid="factoring-confirmation">
              {confirmationLines(state.preview).map((l) => (
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
                Confirm submission
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      )}
    </section>
  );
}
