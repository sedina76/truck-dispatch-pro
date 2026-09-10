"use client";

import { useFormStatus } from "react-dom";
import { Button } from "@/components/ui/button";

// Submit button for <DispatchForm>. useFormStatus() reads the enclosing
// <form>'s pending state natively, so a second click while the create
// action is in flight is a no-op (button disabled) -- server-side
// create_dispatch (0129) + the 0054 unique indexes remain the authoritative
// duplicate guard; this is UX-only.
export function DispatchSubmitButton({
  children,
  pendingText = "Saving…",
}: {
  children: React.ReactNode;
  pendingText?: string;
}) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" disabled={pending} aria-busy={pending}>
      {pending ? pendingText : children}
    </Button>
  );
}
