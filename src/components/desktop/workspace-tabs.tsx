import Link from "next/link";
import { cn } from "@/lib/utils";

export type WorkspaceTab = { label: string; href: string };

// Visual-only document-tab treatment for the CURRENT navigation state --
// not a real persistent multi-tab MDI system (that would need invasive
// routing/state changes the spec explicitly says to skip). Pages pass
// their own real breadcrumb (e.g. "Invoices" -> "INV-000004") built from
// data they already fetched; nothing here is fabricated or remembered
// across navigations.
export function DesktopWorkspaceTabs({ tabs }: { tabs: WorkspaceTab[] }) {
  if (tabs.length === 0) return null;
  return (
    <div className="flex h-7 shrink-0 items-center gap-0.5 border-b border-desktop-border bg-desktop-bg px-1.5 pt-1">
      {tabs.map((tab, i) => {
        const active = i === tabs.length - 1;
        return (
          <Link
            key={tab.href}
            href={tab.href}
            className={cn(
              "flex h-6 items-center rounded-t-sm border border-b-0 px-3 text-[11.5px] font-medium",
              active
                ? "border-desktop-border bg-desktop-panel text-desktop-text"
                : "border-transparent text-muted-foreground hover:bg-desktop-muted"
            )}
          >
            {tab.label}
          </Link>
        );
      })}
    </div>
  );
}
