import { cn } from "@/lib/utils";

// Consistent thin filter/search strip sitting directly above a data grid.
// Purely a styling wrapper -- the actual inputs/selects are page-specific
// (they submit to real searchParams-driven server filtering, same as
// before this redesign).
export function DesktopFilterBar({ className, children }: { className?: string; children: React.ReactNode }) {
  return (
    <div
      className={cn(
        "flex flex-wrap items-end gap-2 rounded-md border border-desktop-border bg-desktop-panel px-2.5 py-2",
        className
      )}
    >
      {children}
    </div>
  );
}

export function DesktopFilterField({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="space-y-0.5">
      <label className="block text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">{label}</label>
      {children}
    </div>
  );
}

export const desktopInputClass =
  "h-7 rounded-sm border border-desktop-border bg-desktop-panel px-2 text-[12px] text-desktop-text shadow-none outline-none focus-visible:border-primary focus-visible:ring-1 focus-visible:ring-primary/40";
