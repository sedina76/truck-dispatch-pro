"use client";

import { useState, useTransition } from "react";
import { CheckCircle2, AlertTriangle, XCircle, Circle, MessageSquarePlus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useToast } from "@/components/ui/toast";
import { SimpleDocumentSlot } from "@/components/loads/simple-document-slot";
import { computePodStatus, POD_STATUS_LABEL } from "@/lib/documents/pod-status";
import { verifyPod, rejectPod } from "@/app/(app)/loads/pod-actions";
import { requestPodFromDriver, type DrawerDocument } from "@/app/(app)/dispatch/board-actions";

// Phase 2I.1 (Part C) -- the Dispatch Drawer's enhanced Documents panel.
// Split into its own file for the same reason communication-panel.tsx is
// -- renders inside the drawer's existing "Documents" DesktopCollapsibleSection,
// never a second stacked panel. Reuses SimpleDocumentSlot, verifyPod/
// rejectPod, and computePodStatus completely unchanged -- this file adds
// layout/prominence/billing-readiness display around them, never a
// second interpretation of POD status or billing readiness.
export function DocumentsPanel({
  dispatchId: _dispatchId,
  loadId,
  loadNumber,
  documents,
  billingReadiness,
  canManageDispatchOps,
  isDelivered,
  onRefresh,
}: {
  dispatchId: string;
  loadId: string;
  loadNumber: string;
  documents: DrawerDocument[];
  billingReadiness: {
    hasVerifiedPod: boolean;
    hasBol: boolean;
    bolRequired: boolean;
    hasRateConfirmation: boolean;
    rateConfirmationRequired: boolean;
    readyToBill: boolean;
  } | null;
  canManageDispatchOps: boolean;
  isDelivered: boolean;
  onRefresh: () => void | Promise<void>;
}) {
  const toast = useToast();
  const [rejectOpen, setRejectOpen] = useState(false);
  const [rejectReason, setRejectReason] = useState("");
  const [pending, startPending] = useTransition();

  const podEntry = documents.find((d) => d.type === "pod") ?? null;
  const podStatus = computePodStatus(podEntry?.doc ?? null);
  const otherDocuments = documents.filter((d) => d.type !== "pod");

  function handleVerify() {
    if (!podEntry?.doc) return;
    startPending(async () => {
      try {
        await verifyPod(podEntry.doc!.id, loadId);
        toast.show("success", "POD verified.");
        await onRefresh();
      } catch (e) {
        toast.show("error", e instanceof Error ? e.message : "Unable to verify POD.");
      }
    });
  }

  function handleReject() {
    if (!podEntry?.doc || !rejectReason.trim()) return;
    startPending(async () => {
      try {
        const fd = new FormData();
        fd.set("reason", rejectReason.trim());
        await rejectPod(podEntry.doc!.id, loadId, fd);
        toast.show("success", "POD rejected.");
        setRejectOpen(false);
        setRejectReason("");
        await onRefresh();
      } catch (e) {
        toast.show("error", e instanceof Error ? e.message : "Unable to reject POD.");
      }
    });
  }

  function handleRequestFromDriver() {
    startPending(async () => {
      const result = await requestPodFromDriver(_dispatchId, loadNumber);
      if (result.ok) toast.show("success", "Message sent to driver -- see Communication.");
      else toast.show("error", result.error);
    });
  }

  const podIcon =
    podStatus === "verified" ? (
      <CheckCircle2 className="size-4 text-desktop-success" />
    ) : podStatus === "rejected" ? (
      <XCircle className="size-4 text-desktop-danger" />
    ) : podStatus === "uploaded" ? (
      <AlertTriangle className="size-4 text-desktop-warning" />
    ) : (
      <Circle className="size-4 text-muted-foreground" />
    );

  return (
    <div className="space-y-3">
      {/* POD prominence (Part C3) -- always shown, more prominent once
          delivered (spec's own "DELIVERY DOCUMENTS" framing). */}
      <div className={cnBorder(podStatus, isDelivered)}>
        <p className="text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">{isDelivered ? "Delivery Documents" : "Proof of Delivery"}</p>
        <div className="mt-1 flex items-center justify-between gap-2">
          <span className="flex items-center gap-1.5 text-sm font-medium">
            {podIcon}
            POD -- {POD_STATUS_LABEL[podStatus]}
            {podStatus === "missing" && isDelivered && <span className="text-xs font-normal text-desktop-danger">(Required for Billing)</span>}
          </span>
        </div>
        {podStatus === "rejected" && podEntry?.doc?.rejection_reason && <p className="mt-1 text-xs text-muted-foreground">Reason: {podEntry.doc.rejection_reason}</p>}

        {billingReadiness && (
          <p className="mt-1.5 text-xs">
            Billing:{" "}
            <span className={billingReadiness.readyToBill ? "font-medium text-desktop-success" : "font-medium text-desktop-warning"}>
              {billingReadiness.readyToBill ? "Ready to Bill" : "Documents Needed"}
            </span>
          </p>
        )}

        <div className="mt-2 flex flex-wrap items-center gap-1.5">
          {canManageDispatchOps && podEntry?.doc && podStatus === "uploaded" && (
            <>
              <Button size="sm" disabled={pending} onClick={handleVerify}>
                Verify POD
              </Button>
              <Button size="sm" variant="outline" disabled={pending} onClick={() => setRejectOpen((o) => !o)}>
                Reject POD
              </Button>
            </>
          )}
          {canManageDispatchOps && (podStatus === "missing" || podStatus === "rejected") && (
            <Button size="sm" variant="outline" disabled={pending} onClick={handleRequestFromDriver}>
              <MessageSquarePlus className="mr-1.5 size-3.5" /> Request from Driver
            </Button>
          )}
        </div>

        {rejectOpen && (
          <div className="mt-2 space-y-1.5">
            <textarea
              value={rejectReason}
              onChange={(e) => setRejectReason(e.target.value)}
              rows={2}
              placeholder="Reason for rejecting this POD..."
              className="w-full rounded-sm border border-desktop-border bg-desktop-panel px-2 py-1.5 text-[13px] outline-none focus-visible:border-primary"
            />
            <div className="flex justify-end gap-1.5">
              <Button size="sm" variant="ghost" onClick={() => setRejectOpen(false)}>
                Cancel
              </Button>
              <Button size="sm" variant="danger" disabled={pending || !rejectReason.trim()} onClick={handleReject}>
                Reject
              </Button>
            </div>
          </div>
        )}

        {/* Upload/Replace/View for POD itself -- same slot, same upload
            action, every other document type in the app already goes
            through. */}
        <div className="mt-2">
          <SimpleDocumentSlot loadId={loadId} documentType="pod" label="POD File" doc={podEntry?.doc ?? null} onUploaded={onRefresh} />
        </div>
      </div>

      {/* Remaining load document types -- unchanged upload/view slot,
          exactly LOAD_DOCUMENT_TYPES (pod-actions.ts). */}
      <div>
        {otherDocuments.map((d) => (
          <SimpleDocumentSlot key={d.type} loadId={loadId} documentType={d.type} label={d.label} doc={d.doc} onUploaded={onRefresh} />
        ))}
      </div>
    </div>
  );
}

function cnBorder(podStatus: string, isDelivered: boolean): string {
  const base = "rounded-md border p-2.5";
  if (podStatus === "missing" && isDelivered) return `${base} border-danger/40 bg-danger/5`;
  if (podStatus === "verified") return `${base} border-desktop-border`;
  return `${base} border-desktop-warning/40 bg-desktop-warning/5`;
}
