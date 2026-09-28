"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { restartMyW9AfterFailure } from "../../actions";

export function RestartW9Button() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <div className="mt-3 space-y-2">
      <button type="button" disabled={pending} className="rounded-sm bg-primary px-3 py-2 text-sm text-primary-foreground disabled:opacity-50"
        onClick={() => startTransition(async () => {
          setError(null);
          try {
            const result = await restartMyW9AfterFailure();
            if (!result.ok) { setError(result.error); return; }
            router.refresh();
          } catch {
            setError("Could not start a new W-9. Please try again.");
          }
        })}>
        {pending ? "Starting..." : "Start a new W-9"}
      </button>
      {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
    </div>
  );
}
