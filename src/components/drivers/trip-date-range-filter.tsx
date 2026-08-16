"use client";

import { useRouter, useSearchParams, usePathname } from "next/navigation";
import { useTransition } from "react";
import { DATE_RANGE_OPTIONS, type DateRangeKey } from "@/lib/drivers/trip-metrics";

export function TripDateRangeFilter({ current }: { current: DateRangeKey }) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [, startTransition] = useTransition();

  function setRange(range: DateRangeKey) {
    const params = new URLSearchParams(searchParams.toString());
    params.set("range", range);
    if (range !== "custom") {
      params.delete("from");
      params.delete("to");
    }
    startTransition(() => {
      router.replace(`${pathname}?${params.toString()}`);
    });
  }

  function setCustomDate(key: "from" | "to", value: string) {
    const params = new URLSearchParams(searchParams.toString());
    params.set("range", "custom");
    if (value) params.set(key, value);
    else params.delete(key);
    startTransition(() => {
      router.replace(`${pathname}?${params.toString()}`);
    });
  }

  return (
    <div className="flex flex-wrap items-center gap-2">
      {DATE_RANGE_OPTIONS.map((opt) => (
        <button
          key={opt.value}
          type="button"
          onClick={() => setRange(opt.value)}
          className={`rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
            current === opt.value
              ? "bg-primary text-primary-foreground"
              : "bg-muted text-muted-foreground hover:bg-muted/70"
          }`}
        >
          {opt.label}
        </button>
      ))}
      {current === "custom" && (
        <div className="flex items-center gap-1.5">
          <input
            type="date"
            defaultValue={searchParams.get("from") ?? ""}
            onChange={(e) => setCustomDate("from", e.target.value)}
            className="h-8 rounded-md border border-border bg-card px-2 text-xs"
          />
          <span className="text-xs text-muted-foreground">to</span>
          <input
            type="date"
            defaultValue={searchParams.get("to") ?? ""}
            onChange={(e) => setCustomDate("to", e.target.value)}
            className="h-8 rounded-md border border-border bg-card px-2 text-xs"
          />
        </div>
      )}
    </div>
  );
}
