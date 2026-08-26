"use client";

import { useState, useTransition } from "react";
import { Eye, Download, KeyRound, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useToast } from "@/components/ui/toast";
import { maskedTin, TAX_CLASSIFICATION_LABELS, type CarrierW9Row } from "@/lib/carrier-w9/types";
import { revealCarrierW9Tin, voidCarrierW9 } from "@/app/(app)/carriers/onboarding/[id]/w9-actions";

// Standalone, reusable W-9 status card (2N.2). Role policy enforced here
// mirrors the DB/route boundary exactly -- this component never trusts
// its own visibility gating as the real security boundary (every action
// it calls independently re-checks role/org server-side):
//   Dispatcher: status + masked TIN only. No PDF, no reveal.
//   Accountant: adds secure View/Download. No reveal.
//   Owner/Admin: adds plaintext reveal (reason-required, audited) and void.
// NOT YET LIVE: depends on migration 0099 (not applied) -- ready for
// integration into the onboarding application detail page and a future
// carrier detail page alike, since CarrierW9Row's shape is identical in
// both contexts.
export function W9StatusCard({
  w9, applicationId, organizationId, role, pdfRouteBase,
}: {
  w9: CarrierW9Row | null;
  applicationId: string;
  organizationId: string;
  role: string;
  pdfRouteBase: string; // e.g. `/carriers/onboarding/${applicationId}/w9`
}) {
  const toast = useToast();
  const canView = ["owner", "admin", "accountant"].includes(role);
  const canReveal = ["owner", "admin"].includes(role);
  const canVoid = ["owner", "admin"].includes(role);

  const [revealing, startReveal] = useTransition();
  const [revealReason, setRevealReason] = useState("");
  const [revealedTin, setRevealedTin] = useState<string | null>(null);
  const [voiding, startVoid] = useTransition();

  if (!w9) {
    return (
      <div className="rounded-md border border-desktop-border bg-card p-4 text-[13px] text-muted-foreground">
        No W-9 has been started for this application yet.
      </div>
    );
  }

  function handleReveal() {
    if (!w9 || !revealReason.trim()) { toast.show("error", "A reason is required to reveal this TIN."); return; }
    startReveal(async () => {
      const result = await revealCarrierW9Tin(w9.id, revealReason.trim());
      if (!result.ok) toast.show("error", result.error);
      else setRevealedTin(result.data.tin);
    });
  }

  function handleVoid() {
    if (!w9) return;
    const reason = prompt("Reason for voiding this W-9?")?.trim();
    if (!reason) return;
    startVoid(async () => {
      const result = await voidCarrierW9(w9.id, applicationId, organizationId, reason);
      if (!result.ok) toast.show("error", result.error);
      else toast.show("success", "W-9 voided.");
    });
  }

  return (
    <div className="min-w-0 space-y-3 rounded-md border border-desktop-border bg-card p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-[14px] font-semibold text-desktop-text">
          Form W-9{w9.version ? ` -- v${w9.version}` : ""}
        </h3>
        <span className="shrink-0 rounded px-1.5 py-0.5 text-[10px] uppercase text-muted-foreground">{w9.status}</span>
      </div>
      <dl className="grid min-w-0 grid-cols-1 gap-x-4 gap-y-1.5 text-[12.5px] sm:grid-cols-2">
        <div className="min-w-0"><dt className="text-muted-foreground">Classification</dt><dd className="wrap-break-word text-desktop-text">{w9.tax_classification ? TAX_CLASSIFICATION_LABELS[w9.tax_classification] : "--"}</dd></div>
        <div className="min-w-0"><dt className="text-muted-foreground">TIN on file</dt><dd className="font-mono text-desktop-text">{revealedTin ?? maskedTin(w9.tin_type, w9.tin_last4)}</dd></div>
      </dl>

      {canView && ["completed", "superseded"].includes(w9.status) && (
        <div className="flex flex-wrap gap-2">
          <a href={`${pdfRouteBase}/${w9.id}/pdf`} target="_blank" rel="noreferrer" className="inline-flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border px-3 text-[12.5px] font-medium hover:bg-muted">
            <Eye className="size-3.5" /> View
          </a>
          <a href={`${pdfRouteBase}/${w9.id}/pdf?download=1`} className="inline-flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border px-3 text-[12.5px] font-medium hover:bg-muted">
            <Download className="size-3.5" /> Download
          </a>
        </div>
      )}

      {canReveal && !revealedTin && (
        <div className="flex min-w-0 flex-wrap items-end gap-2 border-t border-desktop-border pt-3">
          <Input value={revealReason} onChange={(e) => setRevealReason(e.target.value)} placeholder="Reason for revealing this TIN" className="h-8 min-w-0 flex-1 text-[12.5px]" />
          <Button type="button" size="sm" variant="outline" disabled={revealing} onClick={handleReveal}>
            {revealing ? <Loader2 className="size-3.5 animate-spin" /> : <KeyRound className="size-3.5" />} Reveal
          </Button>
        </div>
      )}

      {canVoid && ["draft", "completed"].includes(w9.status) && (
        <div className="border-t border-desktop-border pt-3">
          <Button type="button" size="sm" variant="danger" disabled={voiding} onClick={handleVoid}>
            {voiding ? <Loader2 className="size-3.5 animate-spin" /> : null} Void W-9
          </Button>
        </div>
      )}
    </div>
  );
}
