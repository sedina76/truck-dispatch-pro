"use client";

import { Button } from "@/components/ui/button";

export function ConfirmDeleteForm({ action }: { action: () => Promise<void> }) {
  return (
    <form
      action={action}
      onSubmit={(e) => {
        if (!confirm("Delete this record? This cannot be undone.")) e.preventDefault();
      }}
    >
      <Button type="submit" variant="danger" size="sm">
        Delete
      </Button>
    </form>
  );
}
