"use client";

import { useState } from "react";
import { Loader2 } from "lucide-react";
import { setCompanyFreeAccess } from "@/app/(superadmin)/admin/companies/access-actions";
import { ACCESS_STYLE, type CompanyAccess } from "@/lib/superadmin/company-access";

// "Free access" switch for one company (organizations.billing_required).
// On = the company uses the TMS without a subscription. Off = it needs a
// trial or paid subscription, and without one its users are locked out.
export function FreeAccessControl({ orgId, freeAccess, access }: { orgId: string; freeAccess: boolean; access: CompanyAccess }) {
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function toggle() {
    setSubmitting(true);
    setError(null);
    try {
      await setCompanyFreeAccess(orgId, !freeAccess);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not change access.");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="max-w-lg rounded-xl border border-slate-800 bg-slate-900/60 p-5">
      <div className="flex items-start justify-between gap-4">
        <div>
          <p className="text-sm font-semibold text-slate-100">Access</p>
          <p className="mt-1 text-[12.5px] text-slate-400">{access.detail}</p>
        </div>
        <span className={`inline-flex shrink-0 items-center whitespace-nowrap rounded-full px-2 py-0.5 text-[11px] font-medium ${ACCESS_STYLE[access.key]}`}>{access.label}</span>
      </div>

      <div className="mt-4 flex items-center justify-between gap-4 border-t border-slate-800 pt-4">
        <div>
          <p className="text-[13px] font-medium text-slate-200">Free access</p>
          <p className="text-[12px] text-slate-500">
            {freeAccess ? "Uses the TMS without a subscription. Not billed." : "Needs a trial or paid subscription to use the TMS."}
          </p>
        </div>
        <button
          type="button"
          role="switch"
          aria-checked={freeAccess}
          aria-label="Free access"
          onClick={toggle}
          disabled={submitting}
          className={`relative inline-flex h-6 w-11 shrink-0 items-center rounded-full transition-colors disabled:opacity-60 ${freeAccess ? "bg-blue-500" : "bg-slate-700"}`}
        >
          {submitting ? (
            <Loader2 className="mx-auto size-3.5 animate-spin text-white" />
          ) : (
            <span className={`inline-block size-5 rounded-full bg-white shadow transition-transform ${freeAccess ? "translate-x-5" : "translate-x-0.5"}`} />
          )}
        </button>
      </div>
      {!freeAccess && access.key === "locked" && (
        <p className="mt-3 rounded-lg border border-red-500/25 bg-red-500/10 px-3 py-2 text-[12px] text-red-300">
          This company is locked out right now. Turn on free access, or set a trial or active subscription below.
        </p>
      )}
      {error && <p className="mt-3 text-[12px] text-red-400">{error}</p>}
    </div>
  );
}
