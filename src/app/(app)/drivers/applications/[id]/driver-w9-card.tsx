"use client";

import { useState, useTransition } from "react";
import { Eye, Download, Loader2 } from "lucide-react";
import { RevealPiiButton } from "@/components/ui/reveal-pii-button";
import { maskedTin, type DriverW9Row } from "@/lib/driver-w9/types";
import { revealDriverW9Tin, getDriverW9Url } from "./driver-w9-actions";

// Phase 2Q.2B -- staff-facing Driver W-9 summary. Reuses RevealPiiButton
// (same component every other staff-side PII reveal in this app uses --
// SSN, carrier W-9 TIN) rather than a new reveal control. View/Download
// call getDriverW9Url(), which independently re-checks role server-side
// (owner/admin/accountant) regardless of what this component renders.
export function DriverW9Card({ w9 }: { w9: DriverW9Row | null }) {
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  if (!w9) {
    return <p className="text-sm text-muted-foreground">Not started -- the driver has not yet opened the Tax (W-9) step.</p>;
  }

  const canView = ["completed", "superseded"].includes(w9.status);

  function openUrl(download: boolean) {
    setError(null);
    startTransition(async () => {
      const result = await getDriverW9Url(w9!.id, download);
      if (!result.ok) { setError(result.error); return; }
      window.open(result.url, "_blank", "noopener,noreferrer");
    });
  }

  return (
    <div className="space-y-2 text-sm">
      <p>
        Status: <span className="font-medium capitalize">{w9.status.replace(/_/g, " ")}</span>
        {w9.status === "failed" && w9.failure_reason && <span className="ml-1 text-xs text-destructive">({w9.failure_reason})</span>}
      </p>
      {/* div, not p: RevealPiiButton renders a div at its root, and a div
          can't legally nest inside a p -- the same HTML violation
          src/app/(app)/drivers/applications/[id]/page.tsx's own Field
          component already documents and avoids. React silently "fixes"
          this during hydration by closing the p early, which is exactly
          what produced the reported hydration-mismatch console error.
          Styling is identical to a plain p in this context. */}
      <div>
        TIN on file:{" "}
        <RevealPiiButton maskedValue={maskedTin(w9.tin_type, w9.tin_last4)} onReveal={revealDriverW9Tin.bind(null, w9.id)} promptForReason />
      </div>
      {canView && (
        <div className="flex flex-wrap gap-2 pt-1">
          <button type="button" disabled={pending} onClick={() => openUrl(false)} className="flex items-center gap-1.5 text-xs text-primary disabled:opacity-50">
            {pending ? <Loader2 className="size-3.5 animate-spin" /> : <Eye className="size-3.5" />} View
          </button>
          <button type="button" disabled={pending} onClick={() => openUrl(true)} className="flex items-center gap-1.5 text-xs text-primary disabled:opacity-50">
            <Download className="size-3.5" /> Download
          </button>
        </div>
      )}
      {error && <p className="text-xs text-destructive">{error}</p>}
    </div>
  );
}
