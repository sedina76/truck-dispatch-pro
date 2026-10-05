"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/utils";
import { useOrgRole } from "@/components/auth/role-context";
import { hrefAllowedForRole } from "@/lib/auth/billing-access";
import { workspaceFor } from "@/components/nav/nav-config";

// The tab row for pages grouped under one sidebar entry (nav-config
// WORKSPACES): e.g. Equipment -> Trucks | Trailers. Mounted once in the app
// layout; shows on the workspace's own list pages (not on a record's detail
// page, which has its own breadcrumb tabs) and nowhere else.
// Same look as BillingSubnav. Tabs a role can't open are hidden, and a
// single remaining tab shows no row at all.
export function WorkspaceTabsAuto() {
  const pathname = usePathname();
  const role = useOrgRole();
  const ws = workspaceFor(pathname ?? "");
  if (!ws || pathname !== ws.active) return null;
  const tabs = ws.tabs.filter((t) => hrefAllowedForRole(t.href, role));
  if (tabs.length < 2) return null;
  return (
    <div className="mb-3 flex h-7 shrink-0 items-center gap-0.5 overflow-x-auto border-b border-desktop-border px-0.5 pt-1 print:hidden" data-testid="workspace-tabs">
      {tabs.map((t) => (
        <Link
          key={t.href}
          href={t.href}
          aria-current={t.href === ws.active ? "page" : undefined}
          className={cn(
            "flex h-6 shrink-0 items-center whitespace-nowrap rounded-t-sm border border-b-0 px-3 text-[11.5px] font-medium",
            t.href === ws.active ? "border-desktop-border bg-desktop-panel text-desktop-text" : "border-transparent text-muted-foreground hover:bg-desktop-muted"
          )}
        >
          {t.label}
        </Link>
      ))}
    </div>
  );
}
