"use client";

import { useRouter, usePathname, useSearchParams } from "next/navigation";
import { useTransition } from "react";
import {
  DOCUMENT_TYPE_OPTIONS,
  VERIFICATION_FILTERS,
  EXPIRY_FILTERS,
} from "@/lib/documents/library";
import { DOCUMENT_CATEGORY_FILTERS } from "@/lib/documents/belongs-to";

const SELECT_CLASS =
  "h-8 rounded-sm border border-desktop-border bg-card px-2 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20";

// URL-param filter controls for the Documents library. Same
// searchParams + router.replace pattern as <SearchBar/> -- the page is a
// Server Component that re-queries from these params, so the controls only
// need to rewrite the URL, never hold data.
export function DocumentsFilterBar() {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [, startTransition] = useTransition();

  function setParam(key: string, value: string) {
    const params = new URLSearchParams(searchParams.toString());
    if (value && value !== "all") params.set(key, value);
    else params.delete(key);
    startTransition(() => router.replace(`${pathname}?${params.toString()}`));
  }

  const category = searchParams.get("category") ?? "all";
  const docType = searchParams.get("type") ?? "all";
  const verification = searchParams.get("verification") ?? "all";
  const expiry = searchParams.get("expiry") ?? "all";

  return (
    <div className="flex flex-wrap items-center gap-2">
      <label className="flex items-center gap-1.5 text-[12px] text-muted-foreground">
        Category
        <select className={SELECT_CLASS} value={category} onChange={(e) => setParam("category", e.target.value)}>
          <option value="all">All</option>
          {DOCUMENT_CATEGORY_FILTERS.map((c) => (
            <option key={c.key} value={c.key}>
              {c.label}
            </option>
          ))}
        </select>
      </label>

      <label className="flex items-center gap-1.5 text-[12px] text-muted-foreground">
        Type
        <select className={SELECT_CLASS} value={docType} onChange={(e) => setParam("type", e.target.value)}>
          <option value="all">All</option>
          {DOCUMENT_TYPE_OPTIONS.map((t) => (
            <option key={t.value} value={t.value}>
              {t.label}
            </option>
          ))}
        </select>
      </label>

      <label className="flex items-center gap-1.5 text-[12px] text-muted-foreground">
        Verification
        <select
          className={SELECT_CLASS}
          value={verification}
          onChange={(e) => setParam("verification", e.target.value)}
        >
          {VERIFICATION_FILTERS.map((v) => (
            <option key={v.value} value={v.value}>
              {v.label}
            </option>
          ))}
        </select>
      </label>

      <label className="flex items-center gap-1.5 text-[12px] text-muted-foreground">
        Expiry
        <select className={SELECT_CLASS} value={expiry} onChange={(e) => setParam("expiry", e.target.value)}>
          {EXPIRY_FILTERS.map((v) => (
            <option key={v.value} value={v.value}>
              {v.label}
            </option>
          ))}
        </select>
      </label>
    </div>
  );
}
