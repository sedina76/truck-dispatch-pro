"use client";

import { Button } from "@/components/ui/button";

export function RemoveAdminButton({ action }: { action: () => Promise<void> }) {
  return (
    <form
      action={action}
      onSubmit={(e) => {
        if (!confirm("Revoke platform admin access for this person?")) e.preventDefault();
      }}
    >
      <Button type="submit" variant="danger" size="sm">
        Revoke
      </Button>
    </form>
  );
}
