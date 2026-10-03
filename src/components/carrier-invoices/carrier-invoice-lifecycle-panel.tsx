"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2, FileCheck2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter, DialogClose } from "@/components/ui/dialog";
import { discardCarrierInvoiceDraft, issueCarrierInvoice, markCarrierInvoiceReady, reissueCarrierInvoice } from "@/app/(app)/carrier-invoices/issuance-actions";
import { issueDraftCarrierInvoice } from "@/app/(app)/carrier-invoices/quick-issue-actions";
import { driftSentence, issuanceConfirmationLines, issuanceMessage, newWorkflowKey, tryBegin, type IssuancePreview, type WorkflowOutcome } from "@/lib/factoring/carrier-invoice-issuance";

type Lines = Array<{ label: string; value: string }>;

// Plain-words version of what issuing does (dispatch-service fees stay a separate receivable).
const ISSUE_TEXT =
  "Issuing gives the invoice its number and locks it: the carrier, broker, payment terms and amount can no longer change, and if the carrier factors, where the broker must send payment is saved with it. To fix a mistake later, you void and reissue it. Dispatch-service fees stay a separate receivable: your fee is billed to the carrier on a Dispatch Fee Invoice.";
const ISSUE_REASON = "Load delivered, ready to bill";

// One deliberate, confirmed step of the lifecycle (mark ready / discard / issue / reissue). One idempotency key per opening of the dialog, an in-flight guard against double clicks, the RPC's own safe
// code + message on refusal, and a server refresh (invoice + factoring + fee state) after success. Nothing here is editable except a free-text reason.
function ConfirmStep({ testId, trigger, title, description, lines, needReason, defaultReason = "", reasonLabel = "Note for the history", confirmLabel, variant, run, onDone }: {
  testId: string;
  trigger: string;
  title: string;
  description: string;
  lines: Lines;
  needReason: boolean;
  /** Prefilled reason, so routine steps need one click. */
  defaultReason?: string;
  reasonLabel?: string;
  confirmLabel: string;
  variant?: "primary" | "outline";
  run: (reason: string, key: string) => Promise<WorkflowOutcome>;
  onDone: (o: Extract<WorkflowOutcome, { ok: true }>) => void;
}) {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<{ code: string; message: string } | null>(null);
  const keyRef = useRef("");
  const guard = useRef({ inFlight: false });

  async function confirm() {
    if (needReason && reason.trim().length === 0) {
      setError({ code: "REASON_REQUIRED", message: "A reason is required." });
      return;
    }
    if (!tryBegin(guard.current)) return;
    setBusy(true);
    setError(null);
    try {
      const outcome = await run(reason.trim(), keyRef.current);
      if (outcome.ok) {
        setOpen(false);
        onDone(outcome);
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
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (busy) return;
        if (next) {
          keyRef.current = newWorkflowKey();
          setError(null);
          setReason(defaultReason);
        }
        setOpen(next);
      }}
    >
      <Button type="button" variant={variant ?? "primary"} data-testid={testId} onClick={() => { keyRef.current = newWorkflowKey(); setError(null); setReason(defaultReason); setOpen(true); }}>
        {trigger}
      </Button>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription>{description}</DialogDescription>
        </DialogHeader>
        {lines.length > 0 ? (
          <dl className="grid grid-cols-[auto,1fr] gap-x-4 gap-y-1 text-sm">
            {lines.map((l) => (
              <div key={l.label} className="contents">
                <dt className="text-muted-foreground">{l.label}</dt>
                <dd className="font-medium">{l.value}</dd>
              </div>
            ))}
          </dl>
        ) : null}
        {needReason ? (
          <div>
            <label htmlFor={`${testId}-reason`} className="block text-sm font-medium">
              {reasonLabel}
            </label>
            <input id={`${testId}-reason`} className="mt-1 w-full rounded-md border p-2 text-sm" maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} />
          </div>
        ) : null}
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
            {confirmLabel}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export function CarrierInvoiceLifecyclePanel({ invoiceId, updatedAt, actions, canIssueDraft = false, issuePreview, reissuePreview }: {
  invoiceId: string;
  updatedAt: string;
  actions: { markReady: boolean; discard: boolean; issue: boolean; reissue: boolean };
  /** Owner/admin on a draft: one "Issue invoice" button (mark ready + issue). */
  canIssueDraft?: boolean;
  issuePreview: IssuancePreview | null;
  reissuePreview: IssuancePreview | null;
}) {
  const router = useRouter();
  const [note, setNote] = useState<string | null>(null);
  if (!actions.markReady && !actions.discard && !actions.issue && !actions.reissue) return null;
  const issueLines = issuePreview?.success === true ? issuanceConfirmationLines(issuePreview) : [];
  const reissueOk = reissuePreview?.success === true && reissuePreview?.eligible === true;
  const issued = (o: Extract<WorkflowOutcome, { ok: true }>) => {
    setNote(`The invoice was issued. You can now send the billing packet below.${o.dispatchFeeStatus === "draft_created" ? " A separate dispatch-service fee draft was created and linked." : ""}`);
    router.refresh();
  };

  return (
    <section aria-labelledby="lifecycle-heading" className="space-y-3 rounded-md border p-4">
      <h2 id="lifecycle-heading" className="flex items-center gap-2 text-base font-semibold">
        <FileCheck2 className="h-4 w-4" /> Next step
      </h2>
      {note ? (
        <p role="status" className="text-sm text-green-700">
          {note}
        </p>
      ) : null}
      {issuePreview && issuePreview.success !== true ? (
        <p role="alert" className="text-sm text-amber-900">
          <span className="font-mono text-xs">({String(issuePreview.code ?? "UNKNOWN")})</span> {issuanceMessage(issuePreview)}
        </p>
      ) : null}
      <div className="flex flex-wrap gap-2">
        {canIssueDraft ? (
          <ConfirmStep testId="issue-invoice" trigger="Issue invoice" title="Issue this invoice" description={ISSUE_TEXT} lines={issueLines} needReason defaultReason={ISSUE_REASON} confirmLabel="Issue invoice" run={(reason, key) => issueDraftCarrierInvoice(invoiceId, updatedAt, reason, key)} onDone={issued} />
        ) : actions.markReady ? (
          <ConfirmStep testId="mark-ready" trigger="Mark ready for issue" title="Mark ready for issue" description="The system re-checks the load, carrier, broker and amount. An owner or admin then issues it." lines={issueLines} needReason={false} confirmLabel="Confirm" run={(_r, key) => markCarrierInvoiceReady(invoiceId, updatedAt, key)} onDone={() => { setNote("The invoice is ready for an owner or admin to issue."); router.refresh(); }} />
        ) : null}
        {actions.issue ? (
          <ConfirmStep testId="issue-invoice" trigger="Issue invoice" title="Issue this invoice" description={ISSUE_TEXT} lines={issueLines} needReason defaultReason={ISSUE_REASON} confirmLabel="Issue invoice" run={(reason, key) => issueCarrierInvoice(invoiceId, updatedAt, reason, key)} onDone={issued} />
        ) : null}
        {actions.discard ? (
          <ConfirmStep testId="discard-draft" trigger="Discard draft" variant="outline" title="Discard this draft" description="The draft is cancelled and its load can be invoiced again. A record of the draft is kept." defaultReason="Created by mistake" lines={[]} needReason confirmLabel="Discard draft" run={(reason, key) => discardCarrierInvoiceDraft(invoiceId, updatedAt, reason, key)} onDone={() => { setNote("The draft was discarded and its loads were released."); router.refresh(); }} />
        ) : null}
      </div>
      {actions.reissue ? (
        <div id="reissue" className="space-y-2 border-t pt-3" data-testid="reissue-section">
          <h3 className="text-sm font-semibold">Reissue</h3>
          {reissuePreview && !reissueOk ? (
            <p role="alert" className="text-sm text-amber-900">
              <span className="font-mono text-xs">({String(reissuePreview.code ?? "UNKNOWN")})</span> {issuanceMessage(reissuePreview)}
            </p>
          ) : null}
          {reissueOk && reissuePreview ? (
            <>
              <p className="text-sm">{driftSentence(reissuePreview.drift_dimensions)} A reissue voids this invoice (kept, with your reason) and issues a replacement for the same loads and total using the CURRENT server-resolved terms and routing. It is refused if any factoring submission exists or the invoice has any payment.</p>
              <ConfirmStep testId="reissue-invoice" trigger={reissuePreview.reissue_needed ? "Reissue invoice (required)" : "Reissue invoice"} variant={reissuePreview.reissue_needed ? "primary" : "outline"} title="Void and reissue this invoice" description="The original is voided with your reason and linked to the replacement; nothing is deleted." lines={issuanceConfirmationLines(reissuePreview)} needReason confirmLabel="Confirm void and reissue" run={(reason, key) => reissueCarrierInvoice(invoiceId, updatedAt, reason, key)} onDone={(o) => { setNote("The invoice was voided and reissued."); router.push(`/carrier-invoices/${o.replacementInvoiceId ?? o.invoiceId}`); router.refresh(); }} />
            </>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}
