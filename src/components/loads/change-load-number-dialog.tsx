"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Pencil, AlertTriangle, Loader2 } from "lucide-react";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { changeLoadNumber } from "@/app/(app)/loads/load-number-actions";

// Owner/Admin-only controlled override (0114 revision 2). Mirrors the
// ShareProfileDialog pattern already established in this directory --
// plain useState + a direct async server-action call (not a <form
// action={...}>), since this needs a busy/result state and a "close on
// success" behavior a plain form action doesn't give for free.
export function ChangeLoadNumberDialog({ loadId, currentLoadNumber }: { loadId: string; currentLoadNumber: string }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [newNumber, setNewNumber] = useState(currentLoadNumber);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function resetAndClose() {
    setOpen(false);
    setNewNumber(currentLoadNumber);
    setReason("");
    setError(null);
  }

  async function handleSave() {
    setBusy(true);
    setError(null);
    try {
      const result = await changeLoadNumber(loadId, newNumber, reason);
      if (!result.ok) {
        setError(result.error);
        return;
      }
      setOpen(false);
      setReason("");
      // Server actions' revalidatePath() invalidates the cache, but this
      // dialog is a client component sitting inside an already-rendered
      // page -- refresh() re-runs the server component so the new number
      // actually shows up without a full page reload.
      router.refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not change the load number.");
    } finally {
      setBusy(false);
    }
  }

  const canSave = newNumber.trim().length > 0 && reason.trim().length > 0 && !busy;

  return (
    <>
      <Button type="button" variant="outline" size="sm" onClick={() => setOpen(true)} className="h-7 gap-1.5 px-2.5 text-xs">
        <Pencil className="size-3.5" />
        Change Load Number
      </Button>

      <Dialog open={open} onOpenChange={(next) => (next ? setOpen(true) : resetAndClose())}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2 text-[15px]">
              <Pencil className="size-4 text-primary" />
              Change Load Number
            </DialogTitle>
            <DialogDescription>Current: {currentLoadNumber}</DialogDescription>
          </DialogHeader>

          <div className="space-y-3">
            <Field label="Current Load Number">
              <div className="rounded-sm border border-desktop-border bg-desktop-muted px-2.5 py-1.5 text-[13px] text-desktop-text-muted">
                {currentLoadNumber}
              </div>
            </Field>

            <Field label="New Load Number">
              <input value={newNumber} onChange={(e) => setNewNumber(e.target.value)} className={inputClass} placeholder="LD-000123" />
            </Field>

            <Field label="Reason (required)">
              <textarea
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                rows={3}
                className={inputClass}
                placeholder="Why is this load number changing?"
              />
            </Field>

            <div className="flex items-start gap-2 rounded-sm border border-warning/30 bg-warning/5 px-3 py-2 text-[12px] text-desktop-text">
              <AlertTriangle className="mt-0.5 size-3.5 shrink-0 text-warning" />
              This number becomes locked once the load has a dispatch, an invoice, or a generated/sent billing document --
              it cannot be changed after that point.
            </div>
          </div>

          {error && <p className="mt-2 text-[12.5px] text-danger">{error}</p>}

          <div className="mt-3 flex items-center justify-end gap-2 border-t border-desktop-border pt-3">
            <Button type="button" variant="outline" size="sm" onClick={resetAndClose} disabled={busy}>
              Cancel
            </Button>
            <Button type="button" size="sm" onClick={handleSave} disabled={!canSave}>
              {busy ? <Loader2 className="size-3.5 animate-spin" /> : "Save"}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}

const inputClass =
  "w-full rounded-sm border border-desktop-border bg-desktop-panel px-2 py-1.5 text-[13px] text-desktop-text outline-none focus-visible:border-primary focus-visible:ring-1 focus-visible:ring-primary/40";

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1">
      <label className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">{label}</label>
      {children}
    </div>
  );
}
