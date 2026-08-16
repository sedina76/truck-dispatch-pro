"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { AlertTriangle, CheckCircle2, Loader2 } from "lucide-react";
import { StatusBadge } from "@/components/ui/status-badge";
import { updateMyDispatchStatus } from "@/app/driver-portal/actions";

const STATUS_LABEL: Record<string, string> = {
  assigned: "Assigned",
  accepted: "Accepted",
  en_route_to_pickup: "En Route to Pickup",
  at_pickup: "At Pickup",
  loaded: "Loaded",
  en_route_to_delivery: "In Transit",
  at_delivery: "At Delivery",
  delivered: "Delivered",
};

// Only ever offers statuses that come AFTER the current one in the same
// forward order the server enforces (updateMyDispatchStatus) -- the UI
// can't offer an illegal jump even before the server double-checks it.
export function StatusUpdateControl({
  dispatchId,
  currentStatus,
  order,
  podVerified,
}: {
  dispatchId: string;
  currentStatus: string;
  order: readonly string[];
  podVerified: boolean;
}) {
  const router = useRouter();
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [confirmDelivered, setConfirmDelivered] = useState(false);

  const currentIdx = order.indexOf(currentStatus);
  const nextOptions = currentIdx === -1 ? [] : order.slice(currentIdx + 1);
  const isTerminal = currentStatus === "delivered" || currentStatus === "completed";

  async function apply(target: string) {
    if (target === "delivered" && !confirmDelivered) {
      setConfirmDelivered(true);
      return;
    }
    setBusy(target);
    setError(null);
    try {
      await updateMyDispatchStatus(dispatchId, target);
      setConfirmDelivered(false);
      router.refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not update status.");
    } finally {
      setBusy(null);
    }
  }

  if (isTerminal) {
    return (
      <div id="status" className="flex items-center gap-2 rounded-xl border border-success/30 bg-success/5 px-3 py-2.5 text-sm">
        <CheckCircle2 className="size-4 shrink-0 text-success" />
        Trip delivered. <StatusBadge status={currentStatus} />
      </div>
    );
  }

  return (
    <div id="status" className="space-y-2">
      <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Update Status</p>
      {confirmDelivered && !podVerified && (
        <p className="flex items-start gap-1.5 rounded-lg border border-warning/30 bg-warning/5 px-3 py-2 text-xs text-warning">
          <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
          Proof of Delivery is required for billing. You can still mark this trip delivered now and upload POD right after.
        </p>
      )}
      <div className="flex flex-wrap gap-2">
        {nextOptions.map((status) => (
          <button
            key={status}
            type="button"
            disabled={busy !== null}
            onClick={() => apply(status)}
            className="flex h-11 min-w-[44%] flex-1 items-center justify-center rounded-xl border border-border bg-card px-3 text-sm font-medium disabled:opacity-60"
          >
            {busy === status ? <Loader2 className="size-4 animate-spin" /> : status === "delivered" && confirmDelivered ? "Confirm Delivered" : STATUS_LABEL[status] ?? status}
          </button>
        ))}
      </div>
      {error && <p className="text-xs text-danger">{error}</p>}
    </div>
  );
}
