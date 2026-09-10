"use client";

import { useState } from "react";
import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";

// Inner component so useFormStatus() can read the enclosing <form>'s
// pending state -- prevents a double-submit of the cancel action.
function CancelSubmitButton() {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" variant="danger" size="sm" disabled={pending} aria-busy={pending}>
      {pending ? "Cancelling…" : "Cancel Dispatch"}
    </Button>
  );
}

// Replaces the old hard "Delete" button (spec section 13). Same lightweight
// confirm() gate ConfirmDeleteForm already uses elsewhere in this app, plus
// an optional reason appended to the dispatch's own internal notes -- never
// a destructive delete, since load_tracking_events cascades away on a real
// delete and every other linked table (advances/expenses/settlement items)
// would silently lose its dispatch reference.
export function CancelDispatchForm({ action }: { action: (formData: FormData) => Promise<void> }) {
  const [reason, setReason] = useState("");

  return (
    <form
      action={action}
      onSubmit={(e) => {
        if (!confirm("Cancel this dispatch? The load will be returned to Booked status so it can be re-dispatched. This does not delete any tracking history, documents, or expenses already recorded.")) {
          e.preventDefault();
        }
      }}
      className="flex items-center gap-2"
    >
      <input
        type="text"
        name="reason"
        value={reason}
        onChange={(e) => setReason(e.target.value)}
        placeholder="Reason (optional)"
        className="h-8 w-48 rounded-sm border border-desktop-border bg-card px-2.5 text-[12.5px] outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
      />
      <CancelSubmitButton />
    </form>
  );
}
