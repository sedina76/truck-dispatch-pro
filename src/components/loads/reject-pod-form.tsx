"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { rejectPod } from "@/app/(app)/loads/pod-actions";

export function RejectPodForm({ documentId, loadId }: { documentId: string; loadId: string }) {
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <Button type="button" size="sm" variant="danger" onClick={() => setOpen(true)}>
        Reject
      </Button>
    );
  }

  return (
    <form
      action={rejectPod.bind(null, documentId, loadId)}
      className="flex w-full items-center gap-2 rounded-md border border-danger/30 bg-danger/5 p-2"
    >
      <input
        name="reason"
        required
        placeholder="Reason for rejecting (required)"
        className="h-8 flex-1 rounded-md border border-border bg-card px-2 text-xs shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
      />
      <Button type="submit" size="sm" variant="danger">
        Confirm Reject
      </Button>
    </form>
  );
}
