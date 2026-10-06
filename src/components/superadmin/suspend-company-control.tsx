"use client";

import { useState } from "react";
import { Loader2, ShieldOff, ShieldCheck, AlertTriangle } from "lucide-react";
import { setCompanySuspended } from "@/app/(superadmin)/admin/companies/access-actions";

// Suspend/Reactivate sets organizations.is_active (setCompanySuspended),
// which resolveBillingAccess() enforces for every company -- paying, trial,
// free-access and legacy alike, with or without a plan. This is the one
// shared hook behind both places Suspend Company can be triggered from
// (the Company Detail header button and the per-row 3-dot menu) so the
// confirmation step can't be bypassed from either.
export function useSuspendCompanyAction(orgId: string, suspended: boolean) {
  const [confirming, setConfirming] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function apply(suspend: boolean) {
    setSubmitting(true);
    setError(null);
    try {
      await setCompanySuspended(orgId, suspend);
      setConfirming(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not update company status.");
    } finally {
      setSubmitting(false);
    }
  }

  return {
    suspended,
    submitting,
    confirming,
    error,
    // Suspend is destructive, so it always asks first. Reactivate is the
    // reversible direction and applies immediately.
    requestToggle: () => (suspended ? apply(false) : setConfirming(true)),
    confirmSuspend: () => apply(true),
    cancelConfirm: () => setConfirming(false),
  };
}

export function SuspendConfirmDialog({
  companyName,
  submitting,
  error,
  onConfirm,
  onCancel,
}: {
  companyName: string;
  submitting: boolean;
  error: string | null;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4" onClick={onCancel}>
      <div className="w-full max-w-md rounded-xl border border-slate-800 bg-slate-900 p-5 shadow-2xl" onClick={(e) => e.stopPropagation()}>
        <div className="mb-3 flex items-center gap-2 text-red-400">
          <AlertTriangle className="size-4" />
          <p className="text-sm font-semibold">Suspend {companyName}?</p>
        </div>
        <ul className="mb-4 list-disc space-y-1.5 pl-4 text-[12.5px] text-slate-400">
          <li>Every user at this company is blocked from the app and sees a &ldquo;suspended&rdquo; notice until you reactivate it. This applies to free-access companies too.</li>
          <li>Company data, admins, loads, invoices, and history are <span className="font-medium text-slate-300">not deleted</span> -- this is fully reversible via Reactivate.</li>
        </ul>
        {error && <p className="mb-3 text-[12.5px] text-red-400">{error}</p>}
        <div className="flex justify-end gap-2">
          <button type="button" onClick={onCancel} className="h-9 rounded-lg border border-slate-700 px-3 text-[12.5px] text-slate-300">
            Cancel
          </button>
          <button
            type="button"
            onClick={onConfirm}
            disabled={submitting}
            className="flex h-9 items-center gap-1.5 rounded-lg bg-red-500 px-3 text-[12.5px] font-semibold text-white hover:bg-red-600 disabled:opacity-60"
          >
            {submitting && <Loader2 className="size-3.5 animate-spin" />} Confirm Suspend
          </button>
        </div>
      </div>
    </div>
  );
}

// Full button + dialog, used on the Company Detail page header.
export function SuspendCompanyControl({ orgId, companyName, suspended }: { orgId: string; companyName: string; suspended: boolean }) {
  const { submitting, confirming, error, requestToggle, confirmSuspend, cancelConfirm } = useSuspendCompanyAction(orgId, suspended);

  return (
    <>
      <button
        type="button"
        onClick={requestToggle}
        disabled={submitting}
        className={`flex h-9 items-center gap-1.5 rounded-lg border px-3 text-[12.5px] font-medium disabled:opacity-60 ${
          suspended ? "border-emerald-500/30 text-emerald-400 hover:bg-emerald-500/10" : "border-red-500/30 text-red-400 hover:bg-red-500/10"
        }`}
      >
        {submitting ? <Loader2 className="size-3.5 animate-spin" /> : suspended ? <ShieldCheck className="size-3.5" /> : <ShieldOff className="size-3.5" />}
        {suspended ? "Reactivate Company" : "Suspend Company"}
      </button>
      {confirming && <SuspendConfirmDialog companyName={companyName} submitting={submitting} error={error} onConfirm={confirmSuspend} onCancel={cancelConfirm} />}
    </>
  );
}
