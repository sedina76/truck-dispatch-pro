"use client";

import { useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";

// Thin checkbox wrapper around the EXISTING addBrokerPacketItem /
// removeBrokerPacketItem server actions -- no new logic, no new endpoint.
// Checking calls add (with the candidate's document_id); unchecking calls
// remove (for the current packet item). Both are the same bound server
// actions the previous "Add to packet" / "Remove" buttons used; this only
// changes the control surface from repeated tiny links to one toggle.
export function DocumentToggle({
  checked,
  disabled,
  documentId,
  addAction,
  removeAction,
}: {
  checked: boolean;
  disabled: boolean;
  documentId: string | null;
  addAction: ((formData: FormData) => Promise<void>) | null;
  removeAction: (() => Promise<void>) | null;
}) {
  const router = useRouter();
  const [pending, start] = useTransition();

  function onChange(e: React.ChangeEvent<HTMLInputElement>) {
    const next = e.target.checked;
    start(async () => {
      try {
        if (next && addAction && documentId) {
          const fd = new FormData();
          fd.set("document_id", documentId);
          await addAction(fd);
        } else if (!next && removeAction) {
          await removeAction();
        }
      } finally {
        router.refresh();
      }
    });
  }

  return (
    <span className="inline-flex size-4 shrink-0 items-center justify-center">
      {pending ? (
        <Loader2 className="size-3.5 animate-spin text-muted-foreground" />
      ) : (
        <input
          type="checkbox"
          checked={checked}
          disabled={disabled || pending}
          onChange={onChange}
          className="size-4"
          aria-label={checked ? "Remove from packet" : "Add to packet"}
        />
      )}
    </span>
  );
}
