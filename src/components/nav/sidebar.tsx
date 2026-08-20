"use client";

import { useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { ChevronDown, ChevronRight, ChevronsLeft, ChevronsRight, LogOut } from "lucide-react";
import { cn } from "@/lib/utils";
import { logout } from "@/lib/supabase/actions";
import { Avatar, AvatarFallback, initialsFromName } from "@/components/ui/avatar";
import { type OrgRole, BILLING_WORKSPACE_PREFIXES, visibleSections } from "@/components/nav/nav-config";

// Phase 2G.6: the section/role data itself moved to nav-config.ts so the
// new mobile drawer (mobile-nav.tsx) can share it exactly -- this file is
// now purely the DESKTOP (lg: and up) rendering of that shared data.
// Unchanged visually/behaviorally from Phase 2G.5.
export function Sidebar({
  organizationName,
  fullName,
  role,
}: {
  organizationName: string;
  fullName: string;
  role: string;
}) {
  const pathname = usePathname();
  const [collapsed, setCollapsed] = useState(false);
  const [collapsedGroups, setCollapsedGroups] = useState<Set<string>>(new Set());
  const sections = visibleSections(role as OrgRole);

  function toggleGroup(title: string) {
    setCollapsedGroups((prev) => {
      const next = new Set(prev);
      if (next.has(title)) next.delete(title);
      else next.add(title);
      return next;
    });
  }

  return (
    <nav
      className={cn(
        "relative flex h-full shrink-0 flex-col border-r border-desktop-border bg-sidebar text-sidebar-foreground transition-[width] duration-150",
        collapsed ? "w-12" : "w-56"
      )}
    >
      {/* Nav groups */}
      <div className="flex-1 space-y-0.5 overflow-y-auto px-1.5 py-2">
        {sections.map((section) => {
          const groupCollapsed = collapsedGroups.has(section.title);
          return (
            <div key={section.title}>
              {!collapsed && (
                <button
                  onClick={() => toggleGroup(section.title)}
                  className="flex w-full items-center gap-1 px-1.5 py-1 text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground hover:text-desktop-text"
                >
                  {groupCollapsed ? <ChevronRight className="size-3" /> : <ChevronDown className="size-3" />}
                  {section.title}
                </button>
              )}
              {!groupCollapsed && (
                <div className="space-y-px pb-1.5">
                  {section.items.map((item) => {
                    // "Billing" highlights across the whole workspace
                    // (/billing itself plus the five routes its own
                    // internal subnav links to), not just /billing --
                    // otherwise the sidebar would go dark the moment a
                    // user follows the Billing subnav into e.g. /invoices,
                    // undermining the "one workspace" goal this section
                    // exists for. Nothing else needs this treatment.
                    const matchPrefixes = item.href === "/billing" ? BILLING_WORKSPACE_PREFIXES : [item.href];
                    const active = matchPrefixes.some((p) => pathname === p || (pathname.startsWith(p + "/") && p !== "/dashboard"));
                    return (
                      <Link
                        key={item.label + item.href}
                        href={item.href}
                        title={collapsed ? item.label : undefined}
                        className={cn(
                          "flex items-center gap-2 rounded-sm px-2 py-1 text-[12.5px] font-medium transition-colors",
                          active ? "bg-desktop-selection text-white" : "text-sidebar-foreground/85 hover:bg-desktop-muted"
                        )}
                      >
                        <item.icon className={cn("size-[15px] shrink-0", active ? "text-white" : "text-primary/80")} />
                        {!collapsed && <span className="truncate">{item.label}</span>}
                      </Link>
                    );
                  })}
                </div>
              )}
            </div>
          );
        })}
      </div>

      {/* Collapse toggle */}
      <button
        onClick={() => setCollapsed((c) => !c)}
        className="mx-1.5 mb-1.5 flex items-center justify-center gap-1.5 rounded-sm border border-desktop-border px-2 py-1 text-[11px] font-medium text-muted-foreground transition-colors hover:bg-desktop-muted"
      >
        {collapsed ? <ChevronsRight className="size-3.5" /> : <ChevronsLeft className="size-3.5" />}
        {!collapsed && "Collapse"}
      </button>

      {/* My Info */}
      <div className="border-t border-desktop-border p-2">
        {!collapsed && <p className="px-1 pb-1 text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">My Info</p>}
        <div className="flex items-center gap-2 rounded-sm px-1 py-1">
          <Avatar className="size-7">
            <AvatarFallback className="text-[11px]">{initialsFromName(fullName)}</AvatarFallback>
          </Avatar>
          {!collapsed && (
            <div className="min-w-0 flex-1">
              <p className="truncate text-[12px] font-medium">{fullName}</p>
              <p className="truncate text-[10.5px] capitalize text-muted-foreground">
                {role} &middot; {organizationName}
              </p>
            </div>
          )}
        </div>
        {!collapsed && (
          <form action={logout} className="mt-1">
            <button
              type="submit"
              className="flex w-full items-center gap-1.5 rounded-sm px-1.5 py-1 text-[11.5px] text-danger hover:bg-danger/10"
            >
              <LogOut className="size-3.5" />
              Sign out
            </button>
          </form>
        )}
      </div>
    </nav>
  );
}
