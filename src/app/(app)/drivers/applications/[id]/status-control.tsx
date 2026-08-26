"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { updateApplicationStatus } from "../actions";

const STATUS_OPTIONS = [
  { value: "invited", label: "Invited" },
  { value: "in_progress", label: "In Progress" },
  { value: "submitted", label: "New" },
  { value: "under_review", label: "Under Review" },
  { value: "interview", label: "Interview" },
  { value: "approved", label: "Approved" },
  { value: "rejected", label: "Rejected" },
];

// Phase 2Q.2C repair -- controlled select, not an uncontrolled
// <select defaultValue=...> -- see updateApplicationStatus()'s own header
// comment for exactly why that mattered (a stale defaultValue could be
// submitted after a soft-refresh and silently regress an approved
// application). This component's displayed value is always either the
// server's current status (on load) or exactly what the user picked --
// never a stale snapshot.
export function StatusControl({ applicationId, currentStatus }: { applicationId: string; currentStatus: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [selected, setSelected] = useState(currentStatus);
  const [error, setError] = useState<string | null>(null);

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    startTransition(async () => {
      const result = await updateApplicationStatus(applicationId, selected);
      if (!result.ok) {
        setError(result.error);
        setSelected(currentStatus); // snap back to the real current value, never leave a rejected choice displayed as if it took
        return;
      }
      router.refresh();
    });
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-3">
      <select
        value={selected}
        onChange={(e) => setSelected(e.target.value)}
        disabled={pending}
        className="h-10 w-full rounded-lg border border-border bg-card px-3.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20 disabled:opacity-60"
      >
        {STATUS_OPTIONS.map((opt) => (
          <option key={opt.value} value={opt.value}>
            {opt.label}
          </option>
        ))}
      </select>
      {error && <p className="text-xs text-danger">{error}</p>}
      <Button type="submit" disabled={pending || selected === currentStatus} className="w-full">
        {pending ? <Loader2 className="size-3.5 animate-spin" /> : null} Update Status
      </Button>
    </form>
  );
}
