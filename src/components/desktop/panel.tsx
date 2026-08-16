import { cn } from "@/lib/utils";

// The base "window pane" of the desktop redesign -- a flat, thin-bordered
// panel used everywhere a SaaS-style rounded <Card> used to be. No shadow
// by default (desktop ERP panels sit flush against the workspace, they
// don't float), 1px cool-gray border, small radius.
export function DesktopPanel({ className, children }: { className?: string; children: React.ReactNode }) {
  return (
    <div className={cn("rounded-md border border-desktop-border bg-desktop-panel", className)}>{children}</div>
  );
}

// Blue section header strip (spec section 6: "SECTION HEADERS: blue
// background, white text"). Used for panel titles, never for the data-grid
// column header row itself (that stays a light neutral so dense tables
// don't read as visually loud -- see DesktopDataGrid).
export function DesktopPanelHeader({
  title,
  actions,
  dense,
}: {
  title: React.ReactNode;
  actions?: React.ReactNode;
  dense?: boolean;
}) {
  return (
    <div
      className={cn(
        "flex items-center justify-between gap-2 rounded-t-md bg-desktop-header px-3 text-desktop-header-text",
        dense ? "h-7 text-[11px] font-semibold uppercase tracking-wide" : "h-8 text-xs font-semibold uppercase tracking-wide"
      )}
    >
      <span className="truncate">{title}</span>
      {actions && <div className="flex shrink-0 items-center gap-1">{actions}</div>}
    </div>
  );
}

export function DesktopPanelBody({ className, children }: { className?: string; children: React.ReactNode }) {
  return <div className={cn("p-3", className)}>{children}</div>;
}
