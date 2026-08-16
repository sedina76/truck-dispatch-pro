"use client";

import { FileDown } from "lucide-react";
import { DropdownMenu, DropdownMenuTrigger, DropdownMenuContent, DropdownMenuItem } from "@/components/ui/dropdown-menu";
import { useDesktopActions } from "@/components/desktop/actions-context";
import { cn } from "@/lib/utils";

// Context-aware Export toolbar button. Reads the current page's registered
// export options (real GET routes, already filtered/scoped server-side) --
// never a fixed route, never fake data. Disabled with a truthful tooltip
// when the current page hasn't registered anything exportable.
export function DesktopExportMenu() {
  const { actions } = useDesktopActions();
  const options = actions?.exportOptions ?? [];
  const disabledReason = actions?.exportDisabledReason ?? "Export not available for this view";

  if (options.length === 0) {
    return (
      <button
        type="button"
        title={disabledReason}
        aria-label="Export"
        disabled
        className="inline-flex size-7 shrink-0 items-center justify-center rounded-sm border border-transparent text-desktop-text/80 disabled:pointer-events-none disabled:opacity-35"
      >
        <FileDown className="size-4" />
      </button>
    );
  }

  if (options.length === 1) {
    return (
      <a
        href={options[0].href}
        title={options[0].label}
        aria-label={options[0].label}
        className="inline-flex size-7 shrink-0 items-center justify-center rounded-sm border border-transparent text-desktop-text/80 transition-colors hover:border-desktop-border hover:bg-desktop-muted"
      >
        <FileDown className="size-4" />
      </a>
    );
  }

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button
          type="button"
          title="Export"
          aria-label="Export"
          className="inline-flex size-7 shrink-0 items-center justify-center rounded-sm border border-transparent text-desktop-text/80 transition-colors hover:border-desktop-border hover:bg-desktop-muted"
        >
          <FileDown className="size-4" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-56 rounded-sm p-1 text-[12.5px]">
        {options.map((opt) => (
          <DropdownMenuItem key={opt.href} asChild className="rounded-sm text-[12.5px]">
            <a href={opt.href}>{opt.label}</a>
          </DropdownMenuItem>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
