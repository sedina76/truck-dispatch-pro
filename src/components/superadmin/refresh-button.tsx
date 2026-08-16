"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { RefreshCw } from "lucide-react";

export function RefreshButton() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [lastRefreshed, setLastRefreshed] = useState(() => new Date());

  function handleRefresh() {
    startTransition(() => {
      router.refresh();
      setLastRefreshed(new Date());
    });
  }

  return (
    <div className="flex items-center gap-2.5">
      <span className="text-[11px] text-slate-500">
        Updated {lastRefreshed.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}
      </span>
      <button
        type="button"
        onClick={handleRefresh}
        disabled={pending}
        className="flex size-8 items-center justify-center rounded-lg border border-slate-800 bg-slate-900/60 text-slate-400 transition-colors hover:border-slate-700 hover:text-slate-200 disabled:opacity-60"
        title="Refresh"
      >
        <RefreshCw className={`size-3.5 ${pending ? "animate-spin" : ""}`} />
      </button>
    </div>
  );
}
