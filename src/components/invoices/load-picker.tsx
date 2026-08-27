"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { ChevronsUpDown, Search } from "lucide-react";
import { cn } from "@/lib/utils";
import { Popover, PopoverTrigger, PopoverContent } from "@/components/ui/popover";
import { Command, CommandInput, CommandList, CommandEmpty, CommandItem } from "@/components/ui/command";

// "Select Load first" (spec section 3): selecting a load re-requests
// /invoices/new?load_id=X, which re-renders the page as a Server Component
// with that load's broker/customer/rate/terms already resolved server-side
// (src/lib/billing/party.ts, invoices/new/page.tsx). This component is
// presentation-only -- it never computes a bill-to party, a rate, or a due
// date itself, and the rate it displays is rendered verbatim from
// load_financials.rate (via invoices/new/page.tsx's own load_financials
// query) with no rounding or recalculation; the actual invoice line item
// is re-derived from load_financials.rate again, authoritatively,
// server-side in createInvoice() regardless of what this component ever
// displays. Migration 0112, invoice creation rules, and financial
// calculations are untouched by this file.
//
// UI repair: replaces the previous plain native <select> (crowded once an
// organization has more than a handful of eligible loads, and showed only
// "{load_number} -- {amount}") with a searchable Popover + cmdk Command
// combobox -- the same primitives (@/components/ui/popover,
// @/components/ui/command) already used by this app's command palette
// (src/components/nav/command-palette.tsx), reused here rather than a new
// pattern. cmdk provides Arrow-key navigation and Enter-to-select natively
// on CommandItem; Radix Popover provides Escape-to-close and click-outside
// close natively -- neither is hand-rolled here.
export type InvoiceLoadCandidate = {
  id: string;
  load_number: string;
  rate: number;
  partyName: string | null;
  deliveredAt: string | null;
};

// ~6 rows visible before scrolling, per spec -- one named constant so the
// visual row height and the popover's max-height can never silently drift
// out of sync with each other.
const ROW_HEIGHT_REM = 2.75;
const VISIBLE_ROWS = 6;

export function LoadPicker({ loads }: { loads: InvoiceLoadCandidate[] }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");

  // Deliberately NOT cmdk's own built-in fuzzy filter (shouldFilter):
  // Section 2 asks for search by exactly two fields (load number,
  // broker/customer name) -- a plain, predictable substring match against
  // those two fields only, not a fuzzy score across whatever text happens
  // to be rendered inside each row.
  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return loads;
    return loads.filter((l) => l.load_number.toLowerCase().includes(q) || (l.partyName ?? "").toLowerCase().includes(q));
  }, [loads, query]);

  function selectLoad(id: string) {
    setOpen(false);
    setQuery("");
    router.push(`/invoices/new?load_id=${id}`);
  }

  // "Manual invoice -- no load" (Section 7): kept as a plain button OUTSIDE
  // the Command tree entirely, not a CommandItem -- a CommandItem would be
  // subject to the same search filtering as the load list above, which
  // would make it disappear while typing. Rendering it separately, above
  // the results, guarantees it is always visible and never mixed into the
  // filtered load list.
  function selectManual() {
    setOpen(false);
    setQuery("");
    router.push("/invoices/new");
  }

  return (
    <div className="space-y-1">
      <span id="load-picker-label" className="text-[12px] font-medium text-desktop-text">
        Select Load (optional)
      </span>
      <Popover
        open={open}
        onOpenChange={(next) => {
          setOpen(next);
          if (!next) setQuery("");
        }}
      >
        <PopoverTrigger asChild>
          <button
            type="button"
            aria-labelledby="load-picker-label"
            className="flex h-8 w-full items-center justify-between gap-2 rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
          >
            <span className="flex min-w-0 items-center gap-1.5 truncate text-muted-foreground">
              <Search className="size-3.5 shrink-0" />
              Search a delivered load, or create a manual invoice&hellip;
            </span>
            <ChevronsUpDown className="size-3.5 shrink-0 text-muted-foreground" />
          </button>
        </PopoverTrigger>
        <PopoverContent align="start" sideOffset={4} className="w-[min(38rem,90vw)] p-0">
          <button
            type="button"
            onClick={selectManual}
            className="flex w-full items-center gap-2 rounded-t-xl px-3 py-2.5 text-left text-sm font-medium text-primary outline-none hover:bg-muted focus-visible:bg-muted"
          >
            Manual invoice -- no load
          </button>
          <div className="h-px bg-border" />
          <Command shouldFilter={false}>
            <CommandInput value={query} onValueChange={setQuery} placeholder="Search load #, broker, or customer..." aria-label="Search eligible loads" />
            <div className="flex items-center gap-3 border-b border-border px-2.5 py-1.5 text-[10.5px] font-medium uppercase tracking-wide text-muted-foreground">
              <span className="w-20 shrink-0">Load #</span>
              <span className="min-w-0 flex-1">Bill To</span>
              <span className="w-24 shrink-0 text-right">Gross Rate</span>
              <span className="w-32 shrink-0 text-right">Delivery</span>
            </div>
            <CommandList style={{ maxHeight: `${ROW_HEIGHT_REM * VISIBLE_ROWS}rem` }}>
              <CommandEmpty>{loads.length === 0 ? "No delivered loads without an invoice are on file." : "No eligible loads match your search."}</CommandEmpty>
              {filtered.map((l) => (
                <CommandItem
                  key={l.id}
                  value={l.id}
                  onSelect={() => selectLoad(l.id)}
                  className="flex items-center gap-3"
                  style={{ minHeight: `${ROW_HEIGHT_REM}rem` }}
                >
                  <span className="w-20 shrink-0 truncate font-medium">{l.load_number}</span>
                  <span className="min-w-0 flex-1 truncate text-muted-foreground">{l.partyName ?? "No broker/customer"}</span>
                  <span className="w-24 shrink-0 text-right tabular-nums">{formatRate(l.rate)}</span>
                  <span className={cn("w-32 shrink-0 text-right text-xs", l.deliveredAt ? "text-muted-foreground" : "font-medium text-warning")}>
                    {l.deliveredAt ? formatDeliveryDate(l.deliveredAt) : "Delivery date missing"}
                  </span>
                </CommandItem>
              ))}
            </CommandList>
          </Command>
        </PopoverContent>
      </Popover>
      <p className="text-[11px] text-muted-foreground">
        Only delivered (or later) loads without an existing invoice are listed. Picking a load fills in its billing party, rate, and payment terms
        below.
      </p>
    </div>
  );
}

// Display formatting only -- the exact numeric value from
// load_financials.rate (passed straight through by invoices/new/page.tsx)
// is never rounded or recalculated; toLocaleString here only controls how
// many digits are SHOWN, not what's stored or what createInvoice() later
// reads server-side.
function formatRate(rate: number): string {
  return `$${Number(rate).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

function formatDeliveryDate(iso: string): string {
  return new Date(iso + "T00:00:00Z").toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
}
