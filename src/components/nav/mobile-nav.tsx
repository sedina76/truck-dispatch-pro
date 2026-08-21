"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { ArrowLeft, LayoutDashboard, Package, Radio, Receipt, Menu, X, LogOut } from "lucide-react";
import { cn } from "@/lib/utils";
import { logout } from "@/lib/supabase/actions";
import { Avatar, AvatarFallback, initialsFromName } from "@/components/ui/avatar";
import { useDesktopActions } from "@/components/desktop/actions-context";
import { NotificationsMenu } from "@/components/nav/notifications-menu";
import { type OrgRole, BILLING_WORKSPACE_PREFIXES, visibleSections } from "@/components/nav/nav-config";

type NotificationRow = { id: string; title: string; body: string | null; type: string; entity_type: string | null; entity_id: string | null; read_at: string | null; created_at: string };

// Phase 2G.6: the entire mobile (below lg:, <1024px) staff shell in one
// component -- compact header + bottom nav + "More" drawer -- rendered
// instead of (never alongside) the desktop title bar/menu bar/toolbar/
// sidebar/status bar, which stay `hidden lg:flex` in (app)/layout.tsx.
// Shares its section/role data with the desktop Sidebar via nav-config.ts
// -- there is exactly one nav definition in this app, two renderings of it.
export function MobileShell({
  organizationName,
  fullName,
  role,
  notifications,
}: {
  organizationName: string;
  fullName: string;
  role: string;
  notifications: NotificationRow[];
}) {
  const pathname = usePathname();
  const router = useRouter();
  const { actions } = useDesktopActions();
  const [drawerOpen, setDrawerOpen] = useState(false);

  // Close the drawer automatically on navigation -- otherwise it would
  // still be open over the next page after tapping a link inside it.
  useEffect(() => {
    setDrawerOpen(false);
  }, [pathname]);

  const title = actions?.title ?? organizationName;
  const sections = visibleSections(role as OrgRole);

  const PRIMARY_DESTINATIONS = [
    { label: "Dashboard", href: "/dashboard", icon: LayoutDashboard },
    { label: "Loads", href: "/loads", icon: Package },
    { label: "Tracking", href: "/tracking", icon: Radio },
    { label: "Billing", href: "/billing", icon: Receipt, matchPrefixes: BILLING_WORKSPACE_PREFIXES, roles: ["owner", "admin", "dispatcher", "accountant"] as OrgRole[] },
  ];
  const visiblePrimary = PRIMARY_DESTINATIONS.filter((d) => !d.roles || d.roles.includes(role as OrgRole));

  return (
    <>
      {/* Compact header: back, title, hamburger/notifications -- the
          mobile priority order from spec (back/nav, page title, primary
          action, more actions). Page-specific "primary actions" (Create
          Invoice, etc.) stay in each page's own PageHeader button rather
          than being duplicated up here -- there's no shared registry for
          those the way there is for title/print/export/email. */}
      <div className="flex h-11 shrink-0 items-center gap-1.5 border-b border-desktop-border bg-desktop-header px-2 text-desktop-header-text lg:hidden">
        <button type="button" onClick={() => router.back()} aria-label="Back" className="flex size-8 items-center justify-center rounded-sm hover:bg-white/10">
          <ArrowLeft className="size-4.5" />
        </button>
        <span className="min-w-0 flex-1 truncate text-[13.5px] font-semibold">{title}</span>
        <NotificationsMenu notifications={notifications} />
        <button type="button" onClick={() => setDrawerOpen(true)} aria-label="Open menu" className="flex size-8 items-center justify-center rounded-sm hover:bg-white/10">
          <Menu className="size-5" />
        </button>
      </div>

      {/* Bottom nav: the 5 priority destinations from spec, role-filtered.
          Fixed, sits above the safe-area inset on notched phones. */}
      <nav className="fixed inset-x-0 bottom-0 z-40 flex h-14 shrink-0 items-stretch border-t border-desktop-border bg-desktop-panel pb-[env(safe-area-inset-bottom)] lg:hidden">
        {visiblePrimary.map((dest) => {
          const prefixes = dest.matchPrefixes ?? [dest.href];
          const active = prefixes.some((p) => pathname === p || pathname.startsWith(p + "/"));
          return (
            <Link
              key={dest.href}
              href={dest.href}
              className={cn("flex flex-1 flex-col items-center justify-center gap-0.5 text-[10.5px] font-medium", active ? "text-primary" : "text-muted-foreground")}
            >
              <dest.icon className="size-5" />
              {dest.label}
            </Link>
          );
        })}
        <button type="button" onClick={() => setDrawerOpen(true)} className="flex flex-1 flex-col items-center justify-center gap-0.5 text-[10.5px] font-medium text-muted-foreground">
          <Menu className="size-5" />
          More
        </button>
      </nav>

      {/* "More" drawer: the full categorized nav, same data/role-filtering
          as the desktop sidebar. Full-screen overlay rather than a
          partial slide-in panel -- reliable at every phone width down to
          390px without a separate narrow-panel breakpoint to get wrong. */}
      {drawerOpen && (
        <div className="fixed inset-0 z-50 flex flex-col bg-desktop-bg lg:hidden">
          <div className="flex h-11 shrink-0 items-center gap-2 border-b border-desktop-border bg-desktop-header px-3 text-desktop-header-text">
            <span className="flex-1 text-[13.5px] font-semibold">Menu</span>
            <button type="button" onClick={() => setDrawerOpen(false)} aria-label="Close menu" className="flex size-8 items-center justify-center rounded-sm hover:bg-white/10">
              <X className="size-5" />
            </button>
          </div>

          <div className="flex items-center gap-2 border-b border-desktop-border px-3 py-2.5">
            <Avatar className="size-8">
              <AvatarFallback className="text-[12px]">{initialsFromName(fullName)}</AvatarFallback>
            </Avatar>
            <div className="min-w-0 flex-1">
              <p className="truncate text-[13px] font-medium">{fullName}</p>
              <p className="truncate text-[11px] capitalize text-muted-foreground">
                {role} &middot; {organizationName}
              </p>
            </div>
          </div>

          <div className="flex-1 space-y-3 overflow-y-auto px-3 py-3">
            {sections.map((section) => (
              <div key={section.title}>
                <p className="px-1 pb-1 text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">{section.title}</p>
                <div className="space-y-0.5">
                  {section.items.map((item) => {
                    const matchPrefixes = item.href === "/billing" ? BILLING_WORKSPACE_PREFIXES : [item.href];
                    const active = matchPrefixes.some((p) => pathname === p || pathname.startsWith(p + "/"));
                    return (
                      <Link
                        key={item.label + item.href}
                        href={item.href}
                        className={cn(
                          "flex items-center gap-2.5 rounded-sm px-2 py-2 text-[13.5px] font-medium",
                          active ? "bg-desktop-selection text-white" : "text-desktop-text hover:bg-desktop-muted"
                        )}
                      >
                        <item.icon className={cn("size-4.5 shrink-0", active ? "text-white" : "text-primary/80")} />
                        {item.label}
                      </Link>
                    );
                  })}
                </div>
              </div>
            ))}
          </div>

          <div className="shrink-0 border-t border-desktop-border p-3 pb-[calc(env(safe-area-inset-bottom)+0.75rem)]">
            <form action={logout}>
              <button type="submit" className="flex w-full items-center justify-center gap-1.5 rounded-sm border border-desktop-border px-3 py-2 text-[13px] font-medium text-danger hover:bg-danger/10">
                <LogOut className="size-4" />
                Sign out
              </button>
            </form>
          </div>
        </div>
      )}
    </>
  );
}
