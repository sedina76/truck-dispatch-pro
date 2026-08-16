"use client";

import Link from "next/link";
import { useTheme } from "next-themes";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { openCommandPalette } from "@/components/nav/command-palette";
import { logout } from "@/lib/supabase/actions";

type MenuLink = { label: string; href: string } | { label: string; action: () => void } | "separator";

// Every entry here is a REAL route or a REAL client action -- nothing is
// decorative. Where a classic Windows menu (File/Edit/View/.../Window)
// doesn't map to anything this web app actually does, that menu only
// contains the subset that's genuinely real rather than padding it out
// with dead items. "Window" lists the same set of workspace destinations
// DesktopWorkspaceTabs can show -- there's no real MDI window list to
// draw from, so this is the honest equivalent for a single-window web app.
function menu(label: string, items: MenuLink[]) {
  return { label, items };
}

export function DesktopMenuBar() {
  const { resolvedTheme, setTheme } = useTheme();

  const menus = [
    menu("File", [
      { label: "New Load", href: "/loads/new" },
      { label: "New Invoice", href: "/invoices/new" },
      { label: "New Dispatch", href: "/dispatch/new" },
      "separator",
      { label: "Print Current Page", action: () => window.print() },
      "separator",
      { label: "Sign Out", action: () => logout() },
    ]),
    menu("Edit", [
      { label: "Profile Settings", href: "/settings/profile" },
      { label: "Organization Settings", href: "/settings/organization" },
      { label: "User Management", href: "/settings/users" },
    ]),
    menu("View", [
      { label: resolvedTheme === "dark" ? "Switch to Light Theme" : "Switch to Dark Theme", action: () => setTheme(resolvedTheme === "dark" ? "light" : "dark") },
      { label: "Search / Command Palette", action: () => openCommandPalette() },
    ]),
    menu("Insert", [
      { label: "New Load", href: "/loads/new" },
      { label: "New Driver", href: "/drivers/new" },
      { label: "New Truck", href: "/trucks/new" },
      { label: "New Trailer", href: "/trailers/new" },
      { label: "New Carrier", href: "/carriers/new" },
      { label: "New Broker", href: "/brokers/new" },
      { label: "New Customer", href: "/customers/new" },
      { label: "New Invoice", href: "/invoices/new" },
      { label: "Record Payment", href: "/payments/new" },
      { label: "New Driver Settlement", href: "/driver-settlements/new" },
      { label: "New Carrier Settlement", href: "/settlements/new" },
      { label: "New Expense", href: "/expenses/new" },
    ]),
    menu("Tools", [
      { label: "Integrations", href: "/settings/integrations" },
      { label: "Users & Roles", href: "/settings/users" },
      { label: "Bank Accounts", href: "/settings/organization/bank-accounts" },
      { label: "Subscription", href: "/settings/subscription" },
    ]),
    menu("Reports", [
      { label: "Revenue", href: "/reports/revenue" },
      { label: "Accounts Receivable Aging", href: "/reports/accounts-receivable" },
      { label: "Carrier Performance", href: "/reports/carrier-performance" },
      { label: "Broker Performance", href: "/reports/broker-performance" },
      { label: "Driver Pay", href: "/reports/driver-pay" },
      { label: "Carrier Pay", href: "/reports/carrier-pay" },
      "separator",
      { label: "Profitability", href: "/reports/profitability" },
      { label: "Load Margin", href: "/reports/load-margin" },
      { label: "Lane Profitability", href: "/reports/lane-profitability" },
      { label: "Expenses", href: "/reports/expenses" },
    ]),
    menu("Window", [
      { label: "Dashboard", href: "/dashboard" },
      { label: "Dispatch Board", href: "/dispatch/board" },
      { label: "Accounts Receivable", href: "/accounts-receivable" },
      { label: "Collections", href: "/collections" },
      { label: "Invoices", href: "/invoices" },
      { label: "Payments", href: "/payments" },
      { label: "Statements", href: "/statements" },
      { label: "Driver Settlements", href: "/driver-settlements" },
      { label: "Carrier Settlements", href: "/settlements" },
    ]),
    menu("Help", [
      { label: "Keyboard Shortcuts / Search", action: () => openCommandPalette() },
      { label: "Settings", href: "/settings/profile" },
    ]),
  ];

  return (
    <div className="flex h-7 shrink-0 items-center border-b border-desktop-border bg-desktop-panel px-1 text-[12.5px]">
      {menus.map((m) => (
        <DropdownMenu key={m.label}>
          <DropdownMenuTrigger asChild>
            <button
              type="button"
              className="rounded-sm px-2.5 py-1 text-desktop-text/90 outline-none transition-colors hover:bg-desktop-selection hover:text-white focus-visible:bg-desktop-selection focus-visible:text-white data-[state=open]:bg-desktop-selection data-[state=open]:text-white"
            >
              {m.label}
            </button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="start" className="w-56 rounded-sm p-1 text-[12.5px]">
            {m.items.map((item, idx) =>
              item === "separator" ? (
                <DropdownMenuSeparator key={idx} />
              ) : "href" in item ? (
                <DropdownMenuItem key={item.label} asChild className="rounded-sm text-[12.5px]">
                  <Link href={item.href}>{item.label}</Link>
                </DropdownMenuItem>
              ) : (
                <DropdownMenuItem key={item.label} onSelect={item.action} className="rounded-sm text-[12.5px]">
                  {item.label}
                </DropdownMenuItem>
              )
            )}
          </DropdownMenuContent>
        </DropdownMenu>
      ))}
    </div>
  );
}
