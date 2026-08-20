"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2, HandCoins, History } from "lucide-react";
import { Button } from "@/components/ui/button";
import { StatusBadge } from "@/components/ui/status-badge";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter, DialogClose } from "@/components/ui/dialog";
import { FEE_TIMING_OPTIONS, RECOURSE_TYPE_OPTIONS } from "@/lib/factoring/types";
import {
  submitInvoiceToFactor,
  markFactoredInvoicePending,
  approveFactoredInvoice,
  rejectFactoredInvoice,
  fundFactoredInvoice,
  reportCustomerPaymentToFactor,
  releaseFactoringReserve,
  closeFactoredInvoice,
  markFactoredInvoiceDisputed,
  resolveFactoringDispute,
  startFactoringRecourse,
  recordFactoringChargeback,
  recordFactoringBuyback,
  type FactoringLifecycleResult,
} from "@/app/(app)/invoices/factoring-actions";

function fmtMoney(n: number) {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
function fmtPct(n: number) {
  return `${Number(n).toFixed(2).replace(/\.00$/, "").replace(/(\.\d)0$/, "$1")}%`;
}

export type RelationshipOption = {
  id: string;
  companyName: string;
  relationshipName: string | null;
  advancePercentage: number;
  factoringFeePercentage: number;
  reservePercentage: number;
  feeTiming: string;
  recourseType: string;
};

export type FactoredInvoiceDisplay = {
  id: string;
  status: string;
  companyName: string;
  relationshipName: string | null;
  recourseType: string | null;
  submittedAt: string | null;
  invoiceFaceValue: number;
  advancePercentage: number;
  expectedAdvanceAmount: number;
  factoringFeePercentage: number;
  factoringFeeAmount: number;
  reservePercentage: number;
  reserveAmount: number;
  otherFees: number;
  feeTiming: string;
  expectedFundingAmount: number;
  actualFundedAmount: number | null;
  externalReference: string | null;
  rejectionReason: string | null;
  customerPaidFactorAmount: number | null;
  customerPaidFactorAt: string | null;
  reserveReleasedAmount: number;
  outstandingReserve: number;
  reconciliationStatus: string;
  recourseAmount: number;
  chargebackAmount: number;
  notes: string | null;
};

export type FactoringEventDisplay = {
  id: string;
  eventType: string;
  fromStatus: string | null;
  toStatus: string | null;
  amount: number | null;
  reference: string | null;
  notes: string | null;
  performedByName: string | null;
  createdAt: string;
};

export function FactoringSection({
  invoiceId,
  eligible,
  ineligibleReason,
  activeFactoredInvoice,
  canResubmit,
  historicalFactoredInvoices,
  relationshipOptions,
  defaultRelationshipId,
  events,
}: {
  invoiceId: string;
  eligible: boolean;
  ineligibleReason: string | null;
  activeFactoredInvoice: FactoredInvoiceDisplay | null;
  canResubmit: boolean;
  historicalFactoredInvoices: FactoredInvoiceDisplay[];
  relationshipOptions: RelationshipOption[];
  defaultRelationshipId: string | null;
  events: FactoringEventDisplay[];
}) {
  const [submitOpen, setSubmitOpen] = useState(false);
  // Submitting is offered whenever eligible + a usable relationship
  // exists AND resubmission is currently allowed (no row yet, or the
  // most recent row is rejected/cancelled) -- matches
  // factored_invoices_one_active_per_invoice (0071) exactly, never a
  // re-guess of it.
  const canShowSubmitButton = eligible && relationshipOptions.length > 0 && canResubmit;

  return (
    <div className="rounded-xl border border-border bg-card p-4 shadow-elevation-1">
      <div className="flex items-center justify-between">
        <p className="flex items-center gap-1.5 text-sm font-medium">
          <HandCoins className="size-4" />
          Factoring
        </p>
        {canShowSubmitButton && (
          <Button type="button" size="sm" onClick={() => setSubmitOpen(true)}>
            Submit to Factor
          </Button>
        )}
      </div>

      {activeFactoredInvoice ? (
        <FactoringStatusCard invoiceId={invoiceId} factoredInvoice={activeFactoredInvoice} events={events} />
      ) : (
        <div className="mt-3 text-sm text-muted-foreground">
          {eligible ? (
            relationshipOptions.length > 0 ? (
              "This invoice can be submitted to a factor."
            ) : (
              "No active, currently-effective factoring relationship is configured. Add one under Settings -> Factoring before submitting."
            )
          ) : (
            ineligibleReason
          )}
        </div>
      )}

      {historicalFactoredInvoices.length > 0 && (
        <div className="mt-3 border-t border-border pt-3">
          <p className="flex items-center gap-1.5 text-xs font-medium text-muted-foreground">
            <History className="size-3.5" />
            Prior Factoring Attempts
          </p>
          <div className="mt-2 space-y-1.5">
            {historicalFactoredInvoices.map((fi) => (
              <div key={fi.id} className="flex items-center justify-between text-xs">
                <span>
                  {fi.companyName}
                  {fi.relationshipName ? ` · ${fi.relationshipName}` : ""}
                  {fi.submittedAt ? ` · ${new Date(fi.submittedAt).toLocaleDateString()}` : ""}
                </span>
                <StatusBadge status={fi.status} />
              </div>
            ))}
          </div>
        </div>
      )}

      {submitOpen && (
        <SubmitToFactorDialog
          invoiceId={invoiceId}
          relationshipOptions={relationshipOptions}
          defaultRelationshipId={defaultRelationshipId}
          onClose={() => setSubmitOpen(false)}
        />
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// After-submission card (Phase 2H.4) -- Phase 2H.5 adds status-conditional
// review/approval/funding actions here, and only the ones valid for the
// row's CURRENT status (spec's own table): submitted -> Mark Pending only
// (there is no submitted -> rejected transition in the live graph, so no
// Reject action is offered here); pending -> Approve / Reject; approved ->
// Record Funding; funded -> read-only, no actions. Phase 2H.7 adds the
// exception lifecycle: funded/partially_settled -> Mark Disputed; disputed
// -> Start Recourse / Resolve Dispute; recourse -> Record Chargeback /
// Record Buyback; chargeback and exception-closed rows are read-only --
// there is deliberately no generic "close" action offered directly out of
// disputed or recourse (0078's own header comment has the full reasoning).
// ---------------------------------------------------------------------------
function FactoringStatusCard({ invoiceId, factoredInvoice: fi, events }: { invoiceId: string; factoredInvoice: FactoredInvoiceDisplay; events: FactoringEventDisplay[] }) {
  const router = useRouter();
  const feeTimingLabel = FEE_TIMING_OPTIONS.find((o) => o.value === fi.feeTiming)?.label ?? fi.feeTiming;
  const recourseLabel = fi.recourseType ? (RECOURSE_TYPE_OPTIONS.find((o) => o.value === fi.recourseType)?.label ?? fi.recourseType) : null;

  const [pendingAction, setPendingAction] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [rejectOpen, setRejectOpen] = useState(false);
  const [fundOpen, setFundOpen] = useState(false);
  const [reportPaymentOpen, setReportPaymentOpen] = useState(false);
  const [releaseReserveOpen, setReleaseReserveOpen] = useState(false);
  const [closeConfirmOpen, setCloseConfirmOpen] = useState(false);
  const [disputeOpen, setDisputeOpen] = useState(false);
  const [resolveDisputeOpen, setResolveDisputeOpen] = useState(false);
  const [recourseOpen, setRecourseOpen] = useState(false);
  const [chargebackOpen, setChargebackOpen] = useState(false);
  const [buybackOpen, setBuybackOpen] = useState(false);

  // Informational-only variance display (Phase 2H.6) -- never written back,
  // never gates reconciliation_status itself (the RPCs are the sole
  // authority for that). Only meaningful once a customer payment has
  // actually been reported.
  const expectedNetProceeds = fi.invoiceFaceValue - fi.factoringFeeAmount - fi.otherFees;
  const actualCarrierProceeds = (fi.actualFundedAmount ?? 0) + fi.reserveReleasedAmount;
  const variance = expectedNetProceeds - actualCarrierProceeds;

  async function runAction(key: string, fn: () => Promise<FactoringLifecycleResult>) {
    setPendingAction(key);
    setActionError(null);
    const result = await fn();
    setPendingAction(null);
    if (!result.ok) {
      setActionError(result.error);
      return;
    }
    router.refresh();
  }

  return (
    <div className="mt-3 space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <p className="text-sm font-semibold">
            {fi.companyName}
            {fi.relationshipName && <span className="font-normal text-muted-foreground"> &middot; {fi.relationshipName}</span>}
          </p>
          <p className="text-xs text-muted-foreground">
            Submitted {fi.submittedAt ? new Date(fi.submittedAt).toLocaleString() : "--"}
            {fi.externalReference ? ` · Ref: ${fi.externalReference}` : ""}
          </p>
        </div>
        <StatusBadge status={fi.status} />
      </div>

      <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-xs sm:grid-cols-4">
        <Stat label="Face Value" value={fmtMoney(fi.invoiceFaceValue)} />
        <Stat label="Advance" value={`${fmtPct(fi.advancePercentage)} (${fmtMoney(fi.expectedAdvanceAmount)})`} />
        <Stat label="Factoring Fee" value={`${fmtPct(fi.factoringFeePercentage)} (${fmtMoney(fi.factoringFeeAmount)})`} />
        <Stat label="Reserve" value={`${fmtPct(fi.reservePercentage)} (${fmtMoney(fi.reserveAmount)})`} />
        <Stat label="Fee Timing" value={feeTimingLabel} />
        {recourseLabel && <Stat label="Recourse" value={recourseLabel} />}
        <Stat label="Est. Funding Amount" value={fmtMoney(fi.expectedFundingAmount)} />
        {fi.actualFundedAmount != null && <Stat label="Actual Funded Amount" value={fmtMoney(fi.actualFundedAmount)} />}
        {fi.customerPaidFactorAmount != null && <Stat label="Customer Paid to Factor" value={fmtMoney(fi.customerPaidFactorAmount)} />}
        {fi.reserveAmount > 0 && <Stat label="Reserve Released" value={fmtMoney(fi.reserveReleasedAmount)} />}
        {fi.reserveAmount > 0 && <Stat label="Outstanding Reserve" value={fmtMoney(fi.outstandingReserve)} />}
        {fi.recourseAmount > 0 && <Stat label="Recourse Exposure" value={fmtMoney(fi.recourseAmount)} />}
        {fi.chargebackAmount > 0 && <Stat label="Chargeback Amount" value={fmtMoney(fi.chargebackAmount)} />}
      </div>

      {fi.status === "rejected" && fi.rejectionReason && (
        <div className="rounded-md border border-danger/30 bg-danger/5 p-2.5 text-xs">
          <p className="font-semibold text-danger">Rejection Reason</p>
          <p className="mt-0.5 text-muted-foreground">{fi.rejectionReason}</p>
        </div>
      )}

      {(fi.status === "funded" ||
        fi.status === "partially_settled" ||
        fi.status === "disputed" ||
        fi.status === "recourse" ||
        fi.status === "chargeback" ||
        fi.status === "closed") && (
        <div className="flex flex-wrap items-center gap-3 border-t border-border pt-2 text-xs">
          <span className="flex items-center gap-1">
            Reconciliation:
            <StatusBadge status={fi.reconciliationStatus} />
          </span>
          {fi.customerPaidFactorAt && <span className="text-muted-foreground">Variance: {fmtMoney(variance)}</span>}
        </div>
      )}

      {(fi.status === "submitted" ||
        fi.status === "pending" ||
        fi.status === "approved" ||
        fi.status === "funded" ||
        fi.status === "partially_settled" ||
        fi.status === "disputed" ||
        fi.status === "recourse") && (
        <div className="flex flex-wrap items-center gap-1.5 border-t border-border pt-3">
          {fi.status === "submitted" && (
            <Button type="button" size="sm" variant="outline" disabled={pendingAction === "pending"} onClick={() => runAction("pending", () => markFactoredInvoicePending(invoiceId, fi.id))}>
              {pendingAction === "pending" ? <Loader2 className="size-3.5 animate-spin" /> : null}
              Mark Pending
            </Button>
          )}
          {fi.status === "pending" && (
            <>
              <Button type="button" size="sm" disabled={pendingAction === "approve"} onClick={() => runAction("approve", () => approveFactoredInvoice(invoiceId, fi.id))}>
                {pendingAction === "approve" ? <Loader2 className="size-3.5 animate-spin" /> : null}
                Approve
              </Button>
              <Button type="button" size="sm" variant="outline" onClick={() => setRejectOpen(true)}>
                Reject
              </Button>
            </>
          )}
          {fi.status === "approved" && (
            <Button type="button" size="sm" onClick={() => setFundOpen(true)}>
              Record Funding
            </Button>
          )}
          {(fi.status === "funded" || fi.status === "partially_settled") && (
            <>
              {fi.customerPaidFactorAt == null && (
                <Button type="button" size="sm" onClick={() => setReportPaymentOpen(true)}>
                  Report Customer Payment
                </Button>
              )}
              {fi.customerPaidFactorAt != null && fi.outstandingReserve > 0 && (
                <Button type="button" size="sm" variant="outline" onClick={() => setReleaseReserveOpen(true)}>
                  Record Reserve Release
                </Button>
              )}
              {fi.reconciliationStatus === "reconciled" && (
                <Button type="button" size="sm" variant="outline" disabled={pendingAction === "close"} onClick={() => setCloseConfirmOpen(true)}>
                  {pendingAction === "close" ? <Loader2 className="size-3.5 animate-spin" /> : null}
                  Close Factoring Transaction
                </Button>
              )}
              <Button type="button" size="sm" variant="outline" onClick={() => setDisputeOpen(true)}>
                Mark Disputed
              </Button>
            </>
          )}
          {fi.status === "disputed" && (
            <>
              <Button type="button" size="sm" onClick={() => setRecourseOpen(true)}>
                Start Recourse
              </Button>
              <Button type="button" size="sm" variant="outline" onClick={() => setResolveDisputeOpen(true)}>
                Resolve Dispute
              </Button>
            </>
          )}
          {fi.status === "recourse" && (
            <>
              <Button type="button" size="sm" variant="danger" onClick={() => setChargebackOpen(true)}>
                Record Chargeback
              </Button>
              <Button type="button" size="sm" variant="outline" onClick={() => setBuybackOpen(true)}>
                Record Buyback
              </Button>
            </>
          )}
        </div>
      )}
      {actionError && <p className="text-xs text-danger">{actionError}</p>}

      {events.length > 0 && (
        <div className="border-t border-border pt-2">
          <p className="text-xs font-medium text-muted-foreground">History</p>
          <div className="mt-1 space-y-1">
            {events.map((e) => (
              <div key={e.id} className="flex flex-wrap items-center justify-between gap-x-3 gap-y-0.5 text-xs text-muted-foreground">
                <span className="capitalize">
                  {e.eventType.replace(/_/g, " ")}
                  {e.performedByName ? ` · ${e.performedByName}` : ""}
                  {e.amount != null ? ` · ${fmtMoney(e.amount)}` : ""}
                  {e.reference ? ` · Ref: ${e.reference}` : ""}
                  {e.notes ? ` · ${e.notes}` : ""}
                </span>
                <span>{new Date(e.createdAt).toLocaleString()}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      {rejectOpen && <RejectDialog invoiceId={invoiceId} factoredInvoiceId={fi.id} onClose={() => setRejectOpen(false)} />}
      {fundOpen && <FundDialog invoiceId={invoiceId} factoredInvoiceId={fi.id} externalReference={fi.externalReference} onClose={() => setFundOpen(false)} />}
      {reportPaymentOpen && <ReportPaymentDialog invoiceId={invoiceId} factoredInvoiceId={fi.id} onClose={() => setReportPaymentOpen(false)} />}
      {releaseReserveOpen && (
        <ReleaseReserveDialog invoiceId={invoiceId} factoredInvoiceId={fi.id} outstandingReserve={fi.outstandingReserve} onClose={() => setReleaseReserveOpen(false)} />
      )}
      {closeConfirmOpen && (
        <CloseConfirmDialog
          pending={pendingAction === "close"}
          error={actionError}
          onClose={() => setCloseConfirmOpen(false)}
          onConfirm={async () => {
            await runAction("close", () => closeFactoredInvoice(invoiceId, fi.id));
            setCloseConfirmOpen(false);
          }}
        />
      )}
      {disputeOpen && <DisputeDialog invoiceId={invoiceId} factoredInvoiceId={fi.id} onClose={() => setDisputeOpen(false)} />}
      {resolveDisputeOpen && <ResolveDisputeDialog invoiceId={invoiceId} factoredInvoiceId={fi.id} onClose={() => setResolveDisputeOpen(false)} />}
      {recourseOpen && <RecourseDialog invoiceId={invoiceId} factoredInvoiceId={fi.id} onClose={() => setRecourseOpen(false)} />}
      {chargebackOpen && <ChargebackDialog invoiceId={invoiceId} factoredInvoiceId={fi.id} onClose={() => setChargebackOpen(false)} />}
      {buybackOpen && <BuybackDialog invoiceId={invoiceId} factoredInvoiceId={fi.id} onClose={() => setBuybackOpen(false)} />}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Reject dialog -- reason required (business rule, RPC-enforced, spec
// section 6). Only ever reachable while status='pending' (the button
// itself is not rendered otherwise) -- matches the live transition graph,
// which has no submitted -> rejected pair.
// ---------------------------------------------------------------------------
function RejectDialog({ invoiceId, factoredInvoiceId, onClose }: { invoiceId: string; factoredInvoiceId: string; onClose: () => void }) {
  const router = useRouter();
  const [reason, setReason] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleReject() {
    setPending(true);
    setError(null);
    const result = await rejectFactoredInvoice(invoiceId, factoredInvoiceId, reason);
    setPending(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    router.refresh();
    onClose();
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Reject Factoring Submission</DialogTitle>
          <DialogDescription>A reason is required and is recorded on this factored invoice&apos;s history.</DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Reason
            <textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={3}
              className="w-full rounded-md border border-border bg-card px-2 py-1.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
              placeholder="e.g. Customer credit risk too high for this factor"
            />
          </label>
          {error && <p className="text-xs text-danger">{error}</p>}
        </div>
        <DialogFooter>
          <DialogClose asChild>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
          </DialogClose>
          <Button type="button" variant="danger" onClick={handleReject} disabled={pending || !reason.trim()}>
            {pending ? <Loader2 className="size-3.5 animate-spin" /> : null}
            Reject
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// ---------------------------------------------------------------------------
// Fund dialog -- records the ACTUAL amount the factor funded (never
// derived/validated against expected_funding_amount -- a real factor may
// legitimately fund a different amount, spec section 4/9). External
// reference is optional; leaving it blank preserves whatever value
// already exists rather than erasing it (fund_factored_invoice's own
// coalesce rule, 0076).
// ---------------------------------------------------------------------------
function FundDialog({
  invoiceId,
  factoredInvoiceId,
  externalReference,
  onClose,
}: {
  invoiceId: string;
  factoredInvoiceId: string;
  externalReference: string | null;
  onClose: () => void;
}) {
  const router = useRouter();
  const [amount, setAmount] = useState("");
  const [reference, setReference] = useState(externalReference ?? "");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleFund() {
    const parsed = Number(amount);
    if (!amount || Number.isNaN(parsed) || parsed <= 0) {
      setError("Funded amount must be greater than zero.");
      return;
    }
    setPending(true);
    setError(null);
    const result = await fundFactoredInvoice(invoiceId, factoredInvoiceId, parsed, reference.trim() || null);
    setPending(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    router.refresh();
    onClose();
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Record Funding</DialogTitle>
          <DialogDescription>Enter the actual amount the factor funded -- this does not need to match the estimate shown above.</DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Actual Funded Amount ($)
            <input
              type="number"
              min={0.01}
              step="0.01"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              className="h-8 w-full rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
            />
          </label>
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            External Reference (optional)
            <input
              value={reference}
              onChange={(e) => setReference(e.target.value)}
              placeholder="Factor's wire/confirmation number"
              className="h-8 w-full rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
            />
          </label>
          {error && <p className="text-xs text-danger">{error}</p>}
        </div>
        <DialogFooter>
          <DialogClose asChild>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
          </DialogClose>
          <Button type="button" onClick={handleFund} disabled={pending}>
            {pending ? <Loader2 className="size-3.5 animate-spin" /> : null}
            Record Funding
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className="font-medium">{value}</p>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Submit dialog (spec section 13). Default relationship preselected when
// usable; staff may choose another active/currently-effective relationship
// if more than one is configured. Requires an explicit final click -- no
// automatic factoring.
// ---------------------------------------------------------------------------
function SubmitToFactorDialog({
  invoiceId,
  relationshipOptions,
  defaultRelationshipId,
  onClose,
}: {
  invoiceId: string;
  relationshipOptions: RelationshipOption[];
  defaultRelationshipId: string | null;
  onClose: () => void;
}) {
  const router = useRouter();
  const [relationshipId, setRelationshipId] = useState(defaultRelationshipId ?? relationshipOptions[0]?.id ?? "");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const selected = relationshipOptions.find((r) => r.id === relationshipId) ?? null;

  async function handleSubmit() {
    if (!relationshipId) return;
    setPending(true);
    setError(null);
    const result = await submitInvoiceToFactor(invoiceId, relationshipId);
    setPending(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    router.refresh();
    onClose();
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>Submit to Factor</DialogTitle>
          <DialogDescription>Review the terms before submitting. This cannot be automated or undone from this screen.</DialogDescription>
        </DialogHeader>

        <div className="space-y-3">
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Factoring Relationship
            <select
              value={relationshipId}
              onChange={(e) => setRelationshipId(e.target.value)}
              className="h-8 w-full rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
            >
              {relationshipOptions.map((r) => (
                <option key={r.id} value={r.id}>
                  {r.companyName}
                  {r.relationshipName ? ` – ${r.relationshipName}` : ""}
                  {r.id === defaultRelationshipId ? " (Default)" : ""}
                </option>
              ))}
            </select>
          </label>

          {selected && (
            <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 rounded-md border border-border p-3 text-xs sm:grid-cols-3">
              <Stat label="Advance" value={fmtPct(selected.advancePercentage)} />
              <Stat label="Factoring Fee" value={fmtPct(selected.factoringFeePercentage)} />
              <Stat label="Reserve" value={fmtPct(selected.reservePercentage)} />
              <Stat label="Fee Timing" value={FEE_TIMING_OPTIONS.find((o) => o.value === selected.feeTiming)?.label ?? selected.feeTiming} />
              <Stat label="Recourse" value={RECOURSE_TYPE_OPTIONS.find((o) => o.value === selected.recourseType)?.label ?? selected.recourseType} />
            </div>
          )}

          <p className="text-xs text-muted-foreground">
            Exact dollar amounts (advance, fee, reserve, and estimated funding) are calculated by the server at the moment of submission from the invoice&apos;s
            current total and the relationship&apos;s terms shown above.
          </p>

          {error && <p className="text-xs text-danger">{error}</p>}
        </div>

        <DialogFooter>
          <DialogClose asChild>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
          </DialogClose>
          <Button type="button" onClick={handleSubmit} disabled={pending || !relationshipId}>
            {pending ? <Loader2 className="size-3.5 animate-spin" /> : null}
            Submit to Factor
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// ---------------------------------------------------------------------------
// Report Customer Payment dialog (Phase 2H.6) -- deliberately framed as a
// ONE-TIME final/cumulative report, matching what the schema can safely
// represent (no child payment table -- report_customer_payment_to_factor()
// blocks a second call outright). Never implies partial/individual
// customer payments can be entered here.
// ---------------------------------------------------------------------------
function ReportPaymentDialog({ invoiceId, factoredInvoiceId, onClose }: { invoiceId: string; factoredInvoiceId: string; onClose: () => void }) {
  const router = useRouter();
  const [amount, setAmount] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit() {
    const parsed = Number(amount);
    if (!amount || Number.isNaN(parsed) || parsed <= 0) {
      setError("Customer payment amount must be greater than zero.");
      return;
    }
    setPending(true);
    setError(null);
    const result = await reportCustomerPaymentToFactor(invoiceId, factoredInvoiceId, parsed);
    setPending(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    router.refresh();
    onClose();
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Report Customer Payment to Factor</DialogTitle>
          <DialogDescription>
            Record the final/cumulative amount the factor reports receiving from the customer or broker. This can only be recorded once.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Amount Paid to Factor ($)
            <input
              type="number"
              min={0.01}
              step="0.01"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              className="h-8 w-full rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
            />
          </label>
          {error && <p className="text-xs text-danger">{error}</p>}
        </div>
        <DialogFooter>
          <DialogClose asChild>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
          </DialogClose>
          <Button type="button" onClick={handleSubmit} disabled={pending}>
            {pending ? <Loader2 className="size-3.5 animate-spin" /> : null}
            Report Payment
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// ---------------------------------------------------------------------------
// Release Reserve dialog -- reference optional (matches Record Funding's
// own precedent, spec section 7's resolved idempotency design); when
// provided, the server structurally rejects reusing the same reference
// for a second reserve-release event on this same factored invoice.
// ---------------------------------------------------------------------------
function ReleaseReserveDialog({
  invoiceId,
  factoredInvoiceId,
  outstandingReserve,
  onClose,
}: {
  invoiceId: string;
  factoredInvoiceId: string;
  outstandingReserve: number;
  onClose: () => void;
}) {
  const router = useRouter();
  const [amount, setAmount] = useState("");
  const [reference, setReference] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Generated ONCE when this dialog mounts (lazy initializer -- never
  // re-runs on re-render) and reused for every submit attempt, including
  // a retry after a transient error. This is what makes
  // release_factoring_reserve()'s (0077) idempotency check meaningful:
  // a genuine network retry of the SAME intended release must resend
  // this exact value, never a freshly generated one. Closing and
  // reopening the dialog is a NEW intended release and correctly gets a
  // new key (the component unmounts).
  const [idempotencyKey] = useState(() => crypto.randomUUID());

  async function handleSubmit() {
    const parsed = Number(amount);
    if (!amount || Number.isNaN(parsed) || parsed <= 0) {
      setError("Reserve release amount must be greater than zero.");
      return;
    }
    setPending(true);
    setError(null);
    const result = await releaseFactoringReserve(invoiceId, factoredInvoiceId, parsed, idempotencyKey, reference.trim() || null);
    setPending(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    router.refresh();
    onClose();
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Record Reserve Release</DialogTitle>
          <DialogDescription>Outstanding reserve: {fmtMoney(outstandingReserve)}. Multiple releases are supported until the reserve is fully released.</DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Release Amount ($)
            <input
              type="number"
              min={0.01}
              step="0.01"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              className="h-8 w-full rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
            />
          </label>
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Reference (optional)
            <input
              value={reference}
              onChange={(e) => setReference(e.target.value)}
              placeholder="Factor's wire/statement reference"
              className="h-8 w-full rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
            />
          </label>
          {error && <p className="text-xs text-danger">{error}</p>}
        </div>
        <DialogFooter>
          <DialogClose asChild>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
          </DialogClose>
          <Button type="button" onClick={handleSubmit} disabled={pending}>
            {pending ? <Loader2 className="size-3.5 animate-spin" /> : null}
            Record Release
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// ---------------------------------------------------------------------------
// Close confirmation -- close_factored_invoice() (0077) is the sole
// authority on eligibility (reconciliation_status = 'reconciled'); this
// dialog only confirms intent, it never computes or asserts
// reconciliation itself.
// ---------------------------------------------------------------------------
function CloseConfirmDialog({
  pending,
  error,
  onClose,
  onConfirm,
}: {
  pending: boolean;
  error: string | null;
  onClose: () => void;
  onConfirm: () => void;
}) {
  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Close Factoring Transaction</DialogTitle>
          <DialogDescription>This factoring transaction is fully reconciled. Closing marks it complete -- this cannot be undone from this screen.</DialogDescription>
        </DialogHeader>
        {error && <p className="text-xs text-danger">{error}</p>}
        <DialogFooter>
          <DialogClose asChild>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
          </DialogClose>
          <Button type="button" onClick={onConfirm} disabled={pending}>
            {pending ? <Loader2 className="size-3.5 animate-spin" /> : null}
            Close Transaction
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// ---------------------------------------------------------------------------
// Phase 2H.7 -- exception lifecycle dialogs. Only funded/partially_settled
// -> Mark Disputed, disputed -> Start Recourse / Resolve Dispute, and
// recourse -> Record Chargeback / Record Buyback are offered here -- no
// generic "close from disputed/recourse" dialog exists, matching 0078's
// own deliberate scope boundary.
// ---------------------------------------------------------------------------

// Mark Disputed -- reason required (there is no dedicated dispute-reason
// column; factoring_events.notes is the sole record).
function DisputeDialog({ invoiceId, factoredInvoiceId, onClose }: { invoiceId: string; factoredInvoiceId: string; onClose: () => void }) {
  const router = useRouter();
  const [reason, setReason] = useState("");
  const [reference, setReference] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit() {
    setPending(true);
    setError(null);
    const result = await markFactoredInvoiceDisputed(invoiceId, factoredInvoiceId, reason, reference.trim() || null);
    setPending(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    router.refresh();
    onClose();
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Mark Disputed</DialogTitle>
          <DialogDescription>A reason is required and is recorded on this factored invoice&apos;s history. This does not change any settlement amounts.</DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Reason
            <textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={3}
              className="w-full rounded-md border border-border bg-card px-2 py-1.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
              placeholder="e.g. Customer disputes delivery of this load"
            />
          </label>
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Reference (optional)
            <input
              value={reference}
              onChange={(e) => setReference(e.target.value)}
              placeholder="Factor's dispute/claim number"
              className="h-8 w-full rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
            />
          </label>
          {error && <p className="text-xs text-danger">{error}</p>}
        </div>
        <DialogFooter>
          <DialogClose asChild>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
          </DialogClose>
          <Button type="button" variant="danger" onClick={handleSubmit} disabled={pending || !reason.trim()}>
            {pending ? <Loader2 className="size-3.5 animate-spin" /> : null}
            Mark Disputed
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// Resolve Dispute -- disputed -> partially_settled. Notes optional.
// reconciliation_status is recomputed server-side (resolve_factoring_dispute,
// 0078) against this row's own settlement figures -- never asserted here.
function ResolveDisputeDialog({ invoiceId, factoredInvoiceId, onClose }: { invoiceId: string; factoredInvoiceId: string; onClose: () => void }) {
  const router = useRouter();
  const [notes, setNotes] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit() {
    setPending(true);
    setError(null);
    const result = await resolveFactoringDispute(invoiceId, factoredInvoiceId, notes.trim() || null);
    setPending(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    router.refresh();
    onClose();
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Resolve Dispute</DialogTitle>
          <DialogDescription>Returns this factored invoice to normal settlement. Reconciliation status is recalculated from its current settlement figures.</DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Resolution Notes (optional)
            <textarea
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              rows={3}
              className="w-full rounded-md border border-border bg-card px-2 py-1.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
              placeholder="e.g. Customer confirmed delivery, dispute withdrawn"
            />
          </label>
          {error && <p className="text-xs text-danger">{error}</p>}
        </div>
        <DialogFooter>
          <DialogClose asChild>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
          </DialogClose>
          <Button type="button" onClick={handleSubmit} disabled={pending}>
            {pending ? <Loader2 className="size-3.5 animate-spin" /> : null}
            Resolve Dispute
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// Start Recourse -- disputed -> recourse. ONE-TIME (start_factoring_recourse,
// 0078, structurally cannot be called a second time). Amount and reason
// required.
function RecourseDialog({ invoiceId, factoredInvoiceId, onClose }: { invoiceId: string; factoredInvoiceId: string; onClose: () => void }) {
  const router = useRouter();
  const [amount, setAmount] = useState("");
  const [reason, setReason] = useState("");
  const [reference, setReference] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit() {
    const parsed = Number(amount);
    if (!amount || Number.isNaN(parsed) || parsed <= 0) {
      setError("Recourse amount must be greater than zero.");
      return;
    }
    setPending(true);
    setError(null);
    const result = await startFactoringRecourse(invoiceId, factoredInvoiceId, parsed, reason, reference.trim() || null);
    setPending(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    router.refresh();
    onClose();
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Start Recourse</DialogTitle>
          <DialogDescription>Records the factor invoking recourse on this transaction. This can only be recorded once.</DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Recourse Amount ($)
            <input
              type="number"
              min={0.01}
              step="0.01"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              className="h-8 w-full rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
            />
          </label>
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Reason
            <textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={3}
              className="w-full rounded-md border border-border bg-card px-2 py-1.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
              placeholder="e.g. Factor invoked recourse per agreement terms"
            />
          </label>
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Reference (optional)
            <input
              value={reference}
              onChange={(e) => setReference(e.target.value)}
              placeholder="Factor's recourse notice number"
              className="h-8 w-full rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
            />
          </label>
          {error && <p className="text-xs text-danger">{error}</p>}
        </div>
        <DialogFooter>
          <DialogClose asChild>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
          </DialogClose>
          <Button type="button" variant="danger" onClick={handleSubmit} disabled={pending || !reason.trim()}>
            {pending ? <Loader2 className="size-3.5 animate-spin" /> : null}
            Start Recourse
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// Record Chargeback -- recourse -> chargeback (TERMINAL). ONE-TIME. Amount
// required; reference/reason optional. chargeback_amount is never
// constrained against recourse_amount here -- no such rule exists in the
// live schema (0078's own header comment).
function ChargebackDialog({ invoiceId, factoredInvoiceId, onClose }: { invoiceId: string; factoredInvoiceId: string; onClose: () => void }) {
  const router = useRouter();
  const [amount, setAmount] = useState("");
  const [reference, setReference] = useState("");
  const [reason, setReason] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit() {
    const parsed = Number(amount);
    if (!amount || Number.isNaN(parsed) || parsed <= 0) {
      setError("Chargeback amount must be greater than zero.");
      return;
    }
    setPending(true);
    setError(null);
    const result = await recordFactoringChargeback(invoiceId, factoredInvoiceId, parsed, reference.trim() || null, reason.trim() || null);
    setPending(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    router.refresh();
    onClose();
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Record Chargeback</DialogTitle>
          <DialogDescription>
            The factor has charged this amount back. This is terminal -- there is no further action on this factored invoice after a chargeback is recorded.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Chargeback Amount ($)
            <input
              type="number"
              min={0.01}
              step="0.01"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              className="h-8 w-full rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
            />
          </label>
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Reference (optional)
            <input
              value={reference}
              onChange={(e) => setReference(e.target.value)}
              placeholder="Factor's chargeback notice number"
              className="h-8 w-full rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
            />
          </label>
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Reason (optional)
            <textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={2}
              className="w-full rounded-md border border-border bg-card px-2 py-1.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
            />
          </label>
          {error && <p className="text-xs text-danger">{error}</p>}
        </div>
        <DialogFooter>
          <DialogClose asChild>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
          </DialogClose>
          <Button type="button" variant="danger" onClick={handleSubmit} disabled={pending}>
            {pending ? <Loader2 className="size-3.5 animate-spin" /> : null}
            Record Chargeback
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// Record Buyback -- recourse -> closed. The org repurchases the
// receivable from the factor; factoring_events is the sole, sufficient
// record (0078's own header comment) -- no dedicated column is written
// beyond the standard closed_at/closed_by pair.
function BuybackDialog({ invoiceId, factoredInvoiceId, onClose }: { invoiceId: string; factoredInvoiceId: string; onClose: () => void }) {
  const router = useRouter();
  const [amount, setAmount] = useState("");
  const [reference, setReference] = useState("");
  const [notes, setNotes] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit() {
    const parsed = Number(amount);
    if (!amount || Number.isNaN(parsed) || parsed <= 0) {
      setError("Buyback amount must be greater than zero.");
      return;
    }
    setPending(true);
    setError(null);
    const result = await recordFactoringBuyback(invoiceId, factoredInvoiceId, parsed, reference.trim() || null, notes.trim() || null);
    setPending(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    router.refresh();
    onClose();
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Record Buyback</DialogTitle>
          <DialogDescription>Records the organization repurchasing this receivable from the factor and closes this factoring transaction.</DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Buyback Amount ($)
            <input
              type="number"
              min={0.01}
              step="0.01"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              className="h-8 w-full rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
            />
          </label>
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Reference (optional)
            <input
              value={reference}
              onChange={(e) => setReference(e.target.value)}
              placeholder="Payoff/wire confirmation number"
              className="h-8 w-full rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
            />
          </label>
          <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
            Notes (optional)
            <textarea
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              rows={2}
              className="w-full rounded-md border border-border bg-card px-2 py-1.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
            />
          </label>
          {error && <p className="text-xs text-danger">{error}</p>}
        </div>
        <DialogFooter>
          <DialogClose asChild>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
          </DialogClose>
          <Button type="button" onClick={handleSubmit} disabled={pending}>
            {pending ? <Loader2 className="size-3.5 animate-spin" /> : null}
            Record Buyback
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
