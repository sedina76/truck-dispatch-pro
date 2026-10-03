"use client";

import { useEffect, useRef } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";

// Shown on a W-9 step in the rare moment the W-9 draft is not readable yet:
// instead of a blank page that needed a manual refresh, it reloads the step
// itself (a few times at most) until the form appears.
export function PreparingW9({ title = "Tax (W-9)" }: { title?: string }) {
  const router = useRouter();
  const tries = useRef(0);
  useEffect(() => {
    const id = window.setInterval(() => {
      if (tries.current >= 4) return window.clearInterval(id);
      tries.current += 1;
      router.refresh();
    }, 1200);
    return () => window.clearInterval(id);
  }, [router]);
  return (
    <div className="rounded-md border border-desktop-border bg-card p-4 sm:p-5" role="status">
      <h2 className="text-[15px] font-semibold text-desktop-text">{title}</h2>
      <p className="mt-2 flex items-center gap-2 text-[13px] text-muted-foreground">
        <Loader2 className="size-4 animate-spin" /> Preparing your W-9 form&hellip;
      </p>
      <p className="mt-1 text-[12px] text-muted-foreground">If this takes more than a few seconds, refresh the page.</p>
    </div>
  );
}
