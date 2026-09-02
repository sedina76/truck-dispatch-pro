"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Search, CheckCircle2, AlertTriangle } from "lucide-react";
import {
  searchQuickbooksCustomers,
  mapEntityToQuickbooksCustomer,
  createQuickbooksCustomerForEntity,
} from "@/app/(app)/settings/integrations/quickbooks-sync-actions";
import type { QboCustomer } from "@/lib/integrations/providers/quickbooks";

// Customer/Broker detail "QuickBooks" section. Explicit map (search +
// select) or explicit create -- never a fuzzy auto-map. All work happens in
// server actions; no token ever reaches this component.
export function QuickbooksEntityMapper({
  entityType,
  entityId,
  entityName,
  mapped,
}: {
  entityType: "customer" | "broker";
  entityId: string;
  entityName: string;
  mapped: { displayName: string | null } | null;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [term, setTerm] = useState(entityName);
  const [results, setResults] = useState<QboCustomer[] | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();

  function runSearch() {
    setMsg(null);
    start(async () => {
      const r = await searchQuickbooksCustomers(term);
      if (!r.ok) {
        setMsg(r.message);
        setResults([]);
        return;
      }
      setResults(r.customers);
    });
  }

  function select(id: string) {
    setMsg(null);
    start(async () => {
      const r = await mapEntityToQuickbooksCustomer(entityType, entityId, id);
      if (!r.ok) {
        setMsg(r.message);
        return;
      }
      setOpen(false);
      router.refresh();
    });
  }

  function createNew() {
    setMsg(null);
    start(async () => {
      const r = await createQuickbooksCustomerForEntity(entityType, entityId);
      if (!r.ok) {
        setMsg(r.message);
        return;
      }
      setOpen(false);
      router.refresh();
    });
  }

  return (
    <div className="rounded-md border border-desktop-border bg-card">
      <div className="flex h-7 items-center rounded-t-md bg-desktop-header px-3 text-[11px] font-semibold uppercase tracking-wide text-desktop-header-text">
        QuickBooks
      </div>
      <div className="space-y-2.5 p-3 text-[13px]">
        {mapped ? (
          <div className="flex flex-wrap items-center gap-2">
            <CheckCircle2 className="size-4 shrink-0 text-desktop-success" />
            <span>
              Linked to QuickBooks customer <span className="font-medium">{mapped.displayName ?? "(unnamed)"}</span>
            </span>
            <button
              type="button"
              onClick={() => setOpen((v) => !v)}
              className="ml-auto text-[12px] text-primary hover:underline"
            >
              {open ? "Cancel" : "Change"}
            </button>
          </div>
        ) : (
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-muted-foreground">Not linked to a QuickBooks customer.</span>
            <button
              type="button"
              onClick={() => setOpen((v) => !v)}
              className="ml-auto inline-flex h-7 items-center rounded-sm bg-primary px-2.5 text-[12px] font-medium text-primary-foreground hover:bg-primary-hover"
            >
              {open ? "Cancel" : "Map to QuickBooks"}
            </button>
          </div>
        )}

        {open && (
          <div className="space-y-2 border-t border-desktop-border pt-2.5">
            <div className="flex gap-1.5">
              <div className="flex min-w-0 flex-1 items-center gap-1.5 rounded-sm border border-desktop-border bg-card px-2">
                <Search className="size-3.5 shrink-0 text-muted-foreground" />
                <input
                  value={term}
                  onChange={(e) => setTerm(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && (e.preventDefault(), runSearch())}
                  placeholder="Search QuickBooks customers by name..."
                  className="h-7 w-full bg-transparent text-[13px] outline-none"
                />
              </div>
              <button
                type="button"
                onClick={runSearch}
                disabled={pending}
                className="inline-flex h-7 items-center rounded-sm border border-desktop-border bg-card px-2.5 text-[12px] font-medium hover:bg-muted disabled:opacity-50"
              >
                {pending ? <Loader2 className="size-3.5 animate-spin" /> : "Search"}
              </button>
            </div>

            {results && (
              <div className="max-h-56 space-y-1 overflow-y-auto">
                {results.length === 0 ? (
                  <p className="py-2 text-[12px] text-muted-foreground">No QuickBooks customers match.</p>
                ) : (
                  results.map((c) => (
                    <div key={c.id} className="flex items-center justify-between gap-2 rounded-sm border border-desktop-border px-2 py-1.5">
                      <div className="min-w-0">
                        <p className="truncate font-medium">{c.displayName}</p>
                        {(c.companyName || c.email) && (
                          <p className="truncate text-[11px] text-muted-foreground">{[c.companyName, c.email].filter(Boolean).join(" · ")}</p>
                        )}
                      </div>
                      <button
                        type="button"
                        onClick={() => select(c.id)}
                        disabled={pending}
                        className="inline-flex h-6 shrink-0 items-center rounded-sm bg-primary px-2 text-[11px] font-medium text-primary-foreground hover:bg-primary-hover disabled:opacity-50"
                      >
                        Select
                      </button>
                    </div>
                  ))
                )}
              </div>
            )}

            <div className="border-t border-desktop-border pt-2">
              <button
                type="button"
                onClick={createNew}
                disabled={pending}
                className="inline-flex h-7 items-center rounded-sm border border-desktop-border bg-card px-2.5 text-[12px] font-medium hover:bg-muted disabled:opacity-50"
              >
                {pending ? <Loader2 className="size-3.5 animate-spin" /> : `Create "${entityName}" in QuickBooks`}
              </button>
              <p className="mt-1 text-[11px] text-muted-foreground">
                Only if none of the search results are the right company. This creates a new QuickBooks customer.
              </p>
            </div>

            {msg && (
              <p className="flex items-start gap-1.5 rounded-sm border border-danger/30 bg-danger/5 p-2 text-[12px] text-danger">
                <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
                {msg}
              </p>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
