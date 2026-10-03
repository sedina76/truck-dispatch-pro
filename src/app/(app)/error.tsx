"use client";

import Link from "next/link";
import { AlertTriangle } from "lucide-react";
import { Button } from "@/components/ui/button";

// Any unexpected error on a staff page shows here, INSIDE the app (menus
// stay), instead of the bare "Application error ... Digest" page. The
// reference code is what to look up in the server logs.
export default function AppError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <div className="mx-auto max-w-lg space-y-3 rounded-md border border-desktop-border bg-card p-5">
      <p className="flex items-center gap-2 text-[15px] font-semibold text-desktop-text">
        <AlertTriangle className="size-5 text-danger" /> Something went wrong on this page
      </p>
      <p className="text-[13px] text-muted-foreground">
        The last action may not have finished -- check the record before redoing it. Try again; if it keeps happening, send the reference below to support.
      </p>
      {error.digest && (
        <p className="rounded-sm bg-muted px-2 py-1 font-mono text-[12px]">Reference: {error.digest}</p>
      )}
      <div className="flex gap-2">
        <Button type="button" size="sm" onClick={() => reset()}>Try again</Button>
        <Link href="/dashboard" className="inline-flex h-8 items-center rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">Go to dashboard</Link>
      </div>
    </div>
  );
}
