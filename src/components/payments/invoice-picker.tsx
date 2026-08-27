"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { ChevronsUpDown, Search } from "lucide-react";
import { cn } from "@/lib/utils";
import { Popover, PopoverTrigger, PopoverContent } from "@/components/ui/popover";
import { Command, CommandInput, CommandList, CommandEmpty, CommandItem } from "@/components/ui/command";

// Record Payment's "fully manual" path (no invoice/party preselected from
// an Invoice Detail/A/R/Collections/party-profile link): replaces the
// previous plain native <select> -- crowded once an organization has more
// than a handful of eligible invoices, and showed only
// "{invoice_number} -- ${balance} due" -- with the same searchable
// Popover + cmdk Command combobox already established for the New Invoice
// load picker (src/components/invoices/load-picker.tsx) and this app's
// command palette (src/components/nav/command-palette.tsx). Same
// architecture, reused rather than reinvented: cmdk's CommandItem
// provides Arrow-key navigation and Enter-to-select natively; Radix
// Popover provides Escape-to-close and click-outside-close natively.
//
// Selecting an invoice navigates to /payments/new?invoice_id=<id>, which
// re-renders the page as a Server Component using the SAME
// already-existing "invoice preselected" branch every other entry point
// into Record Payment uses (Invoice Detail's own "Record Payment" link,
// A/R, Collections) -- this component never computes a balance, a Bill To
// party, or performs any eligibility decision itself; it only presents
// server-fetched candidates and triggers that same navigation. The
// existing invoice_id branch already IS the "compact summary + Change"
// surface this repair needs -- nothing new was built for that.
export type InvoicePaymentCandidate = {
  id: string;
  invoiceNumber: string;
  billToName: string;
  loadNumber: string | null;
  totalAmount: number;
  balanceDue: number;
  dueDate: string | null;
};

// ~6 rows visible before scrolling, per spec -- one named constant so the
// visual row height and the popover's max-height can never silently drift
// out of sync with each other (mirrors load-picker.tsx's own constants).
const ROW_HEIGHT_REM = 2.75;
const VISIBLE_ROWS = 6;

export function InvoicePicker({ invoices }: { invoices: InvoicePaymentCandidate[] }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");

  // Plain substring match against exactly the three fields requested
  // (invoice number, broker/customer or Bill To name, linked load
  // number) -- not cmdk's own fuzzy filter, for the same predictability
  // reason load-picker.tsx uses a custom filter instead of shouldFilter.
  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return invoices;
    return invoices.filter(
      (i) =>
        i.invoiceNumber.toLowerCase().includes(q) ||
        i.billToName.toLowerCase().includes(q) ||
        (i.loadNumber ?? "").toLowerCase().includes(q)
    );
  }, [invoices, query]);

  function select(id: string) {
    setOpen(false);
    setQuery("");
    router.push(`/payments/new?invoice_id=${id}`);
  }

  return (
    <div className="space-y-1">
      <span id="invoice-picker-label" className="text-[12px] font-medium text-desktop-text">
        Invoice
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
            aria-labelledby="invoice-picker-label"
            className="flex h-8 w-full items-center justify-between gap-2 rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
          >
            <span className="flex min-w-0 items-center gap-1.5 truncate text-muted-foreground">
              <Search className="size-3.5 shrink-0" />
              Search an invoice with a balance due&hellip;
            </span>
            <ChevronsUpDown className="size-3.5 shrink-0 text-muted-foreground" />
          </button>
        </PopoverTrigger>
        <PopoverContent align="start" sideOffset={4} className="w-[min(46rem,90vw)] p-0">
          <Command shouldFilter={false}>
            <CommandInput value={query} onValueChange={setQuery} placeholder="Search invoice #, broker/customer, or load #..." aria-label="Search eligible invoices" />
            <div className="flex items-center gap-3 border-b border-border px-2.5 py-1.5 text-[10.5px] font-medium uppercase tracking-wide text-muted-foreground">
              <span className="w-24 shrink-0">Invoice #</span>
              <span className="min-w-0 flex-1">Bill To</span>
              <span className="w-16 shrink-0">Load #</span>
              <span className="w-20 shrink-0 text-right">Total</span>
              <span className="w-20 shrink-0 text-right">Balance Due</span>
              <span className="w-20 shrink-0 text-right">Due Date</span>
            </div>
            <CommandList style={{ maxHeight: `${ROW_HEIGHT_REM * VISIBLE_ROWS}rem` }}>
              <CommandEmpty>{invoices.length === 0 ? "No invoices with a balance due are on file." : "No eligible invoices match your search."}</CommandEmpty>
              {filtered.map((i) => (
                <CommandItem
                  key={i.id}
                  value={i.id}
                  onSelect={() => select(i.id)}
                  className="flex items-center gap-3"
                  style={{ minHeight: `${ROW_HEIGHT_REM}rem` }}
                >
                  <span className="w-24 shrink-0 truncate font-medium">{i.invoiceNumber}</span>
                  <span className="min-w-0 flex-1 truncate text-muted-foreground">{i.billToName || "--"}</span>
                  <span className="w-16 shrink-0 truncate">{i.loadNumber ?? "--"}</span>
                  <span className="w-20 shrink-0 text-right tabular-nums">{formatMoney(i.totalAmount)}</span>
                  <span className="w-20 shrink-0 text-right font-medium tabular-nums text-primary">{formatMoney(i.balanceDue)}</span>
                  <span className={cn("w-20 shrink-0 text-right text-xs", i.dueDate ? "text-muted-foreground" : "text-warning")}>
                    {i.dueDate ? formatDueDate(i.dueDate) : "No due date"}
                  </span>
                </CommandItem>
              ))}
            </CommandList>
          </Command>
        </PopoverContent>
      </Popover>
      <p className="text-[11px] text-muted-foreground">Only invoices with a balance due are listed. Paid and void invoices are never shown here.</p>
    </div>
  );
}

// Display formatting only -- never rounds or recalculates the underlying
// value; the actual current balance is re-derived authoritatively
// server-side (the invoice_id branch's own fresh read, and
// guard_payment_amount()'s own re-check at insert time) regardless of
// what this component ever displays.
function formatMoney(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

function formatDueDate(iso: string): string {
  return new Date(iso + "T00:00:00Z").toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
}
