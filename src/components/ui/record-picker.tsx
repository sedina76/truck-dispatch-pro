"use client";

import { useMemo, useState } from "react";
import { ChevronsUpDown, Search } from "lucide-react";
import { Popover, PopoverTrigger, PopoverContent } from "@/components/ui/popover";
import { Command, CommandInput, CommandList, CommandEmpty, CommandItem } from "@/components/ui/command";

// Reusable searchable business-record picker -- the same Popover + cmdk
// Command combobox already established for New Invoice's LoadPicker and
// Record Payment's InvoicePicker (and the command palette). cmdk's
// CommandItem gives Arrow-key navigation and Enter-to-select natively;
// Radix Popover gives Escape / click-outside close and focuses the search
// input on open. This component holds a selected value and shows it in the
// field when closed (unlike the two navigate-on-select pickers).
//
// Presentation only. The caller pre-computes every display string and a
// lowercased `searchText` haystack per option; this never queries, never
// validates ownership, and never lets typed text become an id -- the value
// is always one of `options[].id`. Server-side entity validation and RLS
// are unchanged.

export type RecordOption = {
  id: string;
  primary: string;
  secondary?: string | null;
  tertiary?: string | null;
  /** pre-lowercased text this option matches against */
  searchText: string;
};

const ROW_MIN_REM = 3.25;
const VISIBLE_ROWS = 6;

export function RecordPicker({
  options,
  value,
  onChange,
  placeholder,
  searchPlaceholder,
  emptyLabel,
  disabled = false,
  id,
  ariaLabel,
}: {
  options: RecordOption[];
  value: string | null;
  onChange: (id: string) => void;
  placeholder: string;
  searchPlaceholder: string;
  emptyLabel: string;
  disabled?: boolean;
  id?: string;
  ariaLabel?: string;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");

  const selected = useMemo(() => options.find((o) => o.id === value) ?? null, [options, value]);

  // Plain substring match against the caller-provided haystack -- not
  // cmdk's fuzzy filter, matching LoadPicker/InvoicePicker's own choice
  // for predictable "does it contain what I typed" behavior.
  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return options;
    return options.filter((o) => o.searchText.includes(q));
  }, [options, query]);

  function select(optionId: string) {
    onChange(optionId);
    setOpen(false);
    setQuery("");
  }

  return (
    <Popover
      open={open}
      onOpenChange={(next) => {
        if (disabled) return;
        setOpen(next);
        if (!next) setQuery("");
      }}
    >
      <PopoverTrigger asChild>
        <button
          type="button"
          id={id}
          aria-label={ariaLabel}
          disabled={disabled}
          className="flex h-8 w-full items-center justify-between gap-2 rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20 disabled:opacity-50"
        >
          {selected ? (
            <span className="flex min-w-0 items-baseline gap-1.5 truncate text-desktop-text">
              <span className="shrink-0 font-medium">{selected.primary}</span>
              {selected.secondary && (
                <span className="min-w-0 truncate text-[11px] text-muted-foreground">{selected.secondary}</span>
              )}
            </span>
          ) : (
            <span className="flex min-w-0 items-center gap-1.5 truncate text-muted-foreground">
              <Search className="size-3.5 shrink-0" />
              {placeholder}
            </span>
          )}
          <ChevronsUpDown className="size-3.5 shrink-0 text-muted-foreground" />
        </button>
      </PopoverTrigger>

      <PopoverContent align="start" sideOffset={4} className="w-[min(32rem,92vw)] p-0">
        <Command shouldFilter={false}>
          <CommandInput
            value={query}
            onValueChange={setQuery}
            placeholder={searchPlaceholder}
            aria-label={ariaLabel ?? searchPlaceholder}
          />
          <CommandList style={{ maxHeight: `${ROW_MIN_REM * VISIBLE_ROWS}rem` }}>
            <CommandEmpty>
              {options.length === 0
                ? emptyLabel
                : query.trim()
                  ? `No records match "${query.trim()}".`
                  : emptyLabel}
            </CommandEmpty>
            {filtered.map((o) => (
              <CommandItem
                key={o.id}
                value={o.id}
                onSelect={() => select(o.id)}
                className="flex flex-col items-start gap-0.5"
                style={{ minHeight: `${ROW_MIN_REM}rem` }}
              >
                <span className="w-full truncate text-[13px] font-semibold text-desktop-text">{o.primary}</span>
                {o.secondary && (
                  <span className="w-full truncate text-[12px] text-muted-foreground">{o.secondary}</span>
                )}
                {o.tertiary && (
                  <span className="w-full truncate text-[11px] text-muted-foreground">{o.tertiary}</span>
                )}
              </CommandItem>
            ))}
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}
