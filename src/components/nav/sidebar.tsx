"use client";

import { useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import {
  LayoutDashboard,
  KanbanSquare,
  Package,
  Truck,
  Building2,
  Users,
  UserRound,
  Container,
  Wrench,
  Fuel,
  FileText,
  ShieldCheck,
  Receipt,
  Wallet,
  FileStack,
  TrendingUp,
  HandCoins,
  ShieldAlert,
  BellRing,
  BarChart3,
  ChevronDown,
  ChevronRight,
  ChevronsLeft,
  ChevronsRight,
  LogOut,
  Radio,
  UserPlus,
  UserCog,
  Settings,
  LifeBuoy,
  CheckSquare,
  ReceiptText,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { logout } from "@/lib/supabase/actions";
import { Avatar, AvatarFallback, initialsFromName } from "@/components/ui/avatar";

type NavItem = { label: string; href: string; icon: React.ComponentType<{ className?: string }> };
type NavSection = { title: string; items: NavItem[] };

// Grouped per the Truck Dispatch Pro desktop redesign spec exactly:
// OPERATIONS / FLEET / ACCOUNTING / BUSINESS / ADMINISTRATION. Every href
// is a real existing route -- "Promises to Pay"/"Disputes"/"Reminders"
// don't have dedicated top-level pages of their own (that data lives in
// the Collections queue + Invoice Detail's Collections section), so they
// route into Collections itself, filtered where a matching filter already
// exists (Disputes -> ?filter=disputed) rather than a plain duplicate link.
const SECTIONS: NavSection[] = [
  {
    title: "Operations",
    items: [
      { label: "Dashboard", href: "/dashboard", icon: LayoutDashboard },
      { label: "Dispatch Board", href: "/dispatch/board", icon: KanbanSquare },
      { label: "Loads", href: "/loads", icon: Package },
      { label: "Live Tracking", href: "/tracking", icon: Radio },
    ],
  },
  {
    title: "Fleet",
    items: [
      { label: "Drivers", href: "/drivers", icon: UserRound },
      { label: "Driver Applications", href: "/drivers/applications", icon: UserPlus },
      { label: "Trucks", href: "/trucks", icon: Truck },
      { label: "Trailers", href: "/trailers", icon: Container },
      { label: "Maintenance", href: "/maintenance", icon: Wrench },
      { label: "Fuel Logs", href: "/fuel", icon: Fuel },
    ],
  },
  {
    title: "Accounting",
    items: [
      { label: "Invoicing", href: "/invoices", icon: Receipt },
      { label: "Payments", href: "/payments", icon: Wallet },
      { label: "Statements", href: "/statements", icon: FileStack },
      { label: "Accounts Receivable", href: "/accounts-receivable", icon: TrendingUp },
      { label: "Collections", href: "/collections", icon: ShieldAlert },
      { label: "Promises to Pay", href: "/collections", icon: HandCoins },
      { label: "Disputes", href: "/collections?filter=disputed", icon: ShieldAlert },
      { label: "Reminders", href: "/collections", icon: BellRing },
      { label: "Carrier Settlements", href: "/settlements", icon: HandCoins },
      { label: "Driver Settlements", href: "/driver-settlements", icon: UserRound },
      { label: "Advances", href: "/advances", icon: Wallet },
      { label: "Expenses", href: "/expenses", icon: ReceiptText },
    ],
  },
  {
    title: "Business",
    items: [
      { label: "Carriers", href: "/carriers", icon: Truck },
      { label: "Brokers", href: "/brokers", icon: Building2 },
      { label: "Customers", href: "/customers", icon: Users },
      { label: "Documents", href: "/documents", icon: FileText },
      { label: "Compliance", href: "/compliance", icon: ShieldCheck },
      { label: "Reports", href: "/reports", icon: BarChart3 },
      { label: "Tasks", href: "/dashboard", icon: CheckSquare },
    ],
  },
  {
    title: "Administration",
    items: [
      { label: "Users", href: "/settings/users", icon: UserCog },
      { label: "Settings", href: "/settings/organization", icon: Settings },
      { label: "Help", href: "/settings/profile", icon: LifeBuoy },
    ],
  },
];

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
        {SECTIONS.map((section) => {
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
                    const active = pathname === item.href || (pathname.startsWith(item.href + "/") && item.href !== "/dashboard");
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
