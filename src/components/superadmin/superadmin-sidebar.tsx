"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { LayoutDashboard, Building2, CreditCard, FileText, ShieldCheck, ScrollText, HeartPulse, BarChart3, Settings, LogOut, Radar } from "lucide-react";
import { cn } from "@/lib/utils";
import { logout } from "@/lib/supabase/actions";

const NAV_ITEMS = [
  { label: "Overview", href: "/admin/dashboard", icon: LayoutDashboard },
  { label: "Companies", href: "/admin/companies", icon: Building2 },
  { label: "Subscriptions", href: "/admin/subscriptions", icon: CreditCard },
  { label: "Billing", href: "/admin/billing", icon: FileText },
  { label: "Platform Admins", href: "/admin/admins", icon: ShieldCheck },
  { label: "Audit Log", href: "/admin/audit-log", icon: ScrollText },
  { label: "System Health", href: "/admin/system-health", icon: HeartPulse },
];

// Reports/Settings have no underlying feature yet (no report-generation
// infra, no platform-console-specific settings storage) -- shown as
// disabled "Coming soon" rather than routed to a fake destination, per
// "only make an item functional if the underlying feature exists."
const COMING_SOON_ITEMS = [
  { label: "Reports", icon: BarChart3 },
  { label: "Settings", icon: Settings },
];

export function SuperAdminSidebar() {
  const pathname = usePathname();

  return (
    <nav className="flex h-full w-64 shrink-0 flex-col border-r border-slate-800 bg-slate-950 text-slate-300">
      <div className="flex h-16 shrink-0 items-center gap-2.5 border-b border-slate-800 px-4">
        <div className="flex size-8 shrink-0 items-center justify-center rounded-lg bg-blue-500 text-white shadow-[0_0_16px_-4px_rgba(59,130,246,0.6)]">
          <Radar className="size-4" />
        </div>
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-semibold tracking-tight text-slate-50">Platform Console</p>
          <p className="text-xs text-slate-500">Cross-tenant admin</p>
        </div>
      </div>

      <div className="flex-1 space-y-0.5 overflow-y-auto px-3 py-4">
        {NAV_ITEMS.map((item) => {
          const active = pathname === item.href || pathname.startsWith(item.href + "/");
          return (
            <Link
              key={item.href}
              href={item.href}
              className={cn(
                "flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm font-medium transition-colors",
                active ? "bg-blue-500/10 text-blue-400" : "text-slate-400 hover:bg-slate-900 hover:text-slate-200"
              )}
            >
              <item.icon className="size-[18px] shrink-0" />
              {item.label}
            </Link>
          );
        })}

        <div className="mt-3 border-t border-slate-800 pt-3">
          {COMING_SOON_ITEMS.map((item) => (
            <div key={item.label} className="flex cursor-not-allowed items-center justify-between gap-2.5 rounded-lg px-2.5 py-2 text-sm font-medium text-slate-600">
              <span className="flex items-center gap-2.5">
                <item.icon className="size-[18px] shrink-0" />
                {item.label}
              </span>
              <span className="text-[9.5px] font-semibold uppercase tracking-wide text-slate-700">Soon</span>
            </div>
          ))}
        </div>
      </div>

      <div className="border-t border-slate-800 p-3">
        <form action={logout}>
          <button type="submit" className="flex w-full items-center gap-2 rounded-md px-2.5 py-2 text-sm text-red-400 hover:bg-red-500/10">
            <LogOut className="size-4" />
            Sign out
          </button>
        </form>
      </div>
    </nav>
  );
}
