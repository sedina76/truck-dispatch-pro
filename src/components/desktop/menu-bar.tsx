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
import { useOrgRole } from "@/components/auth/role-context";
import { hrefAllowedForRole } from "@/lib/auth/billing-access";

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

/** Items this role can open, with no leading, trailing or doubled separators left behind. */
export function visibleItems(items: MenuLink[], role: string | null | undefined): MenuLink[] {
  const out: MenuLink[] = [];
  for (const item of items) {
    if (item === "separator") {
      if (out.length > 0 && out[out.length - 1] !== "separator") out.push(item);
    } else if (!("href" in item) || hrefAllowedForRole(item.href, role)) {
      out.push(item);
    }
  }
  while (out[out.length - 1] === "separator") out.pop();
  return out;
}

export function DesktopMenuBar() {
  const { resolvedTheme, setTheme } = useTheme();
  const role = useOrgRole();

  // Ordered the way the work flows: book a load -> dispatch it -> track it
  // -> bill it (your invoice or the carrier's) -> get paid -> settle / bill
  // the carrier its fee.
  const menus = [
    menu("File", [
      { label: "New Load", href: "/loads/new" },
      { label: "New Dispatch", href: "/dispatch/new" },
      "separator",
      { label: "Print Current Page", action: () => window.print() },
      "separator",
      { label: "Sign Out", action: () => logout() },
    ]),
    menu("Edit", [
      { label: "My Profile", href: "/settings/profile" },
      { label: "Organization Settings", href: "/settings/organization" },
      { label: "Users & Roles", href: "/settings/users" },
    ]),
    menu("View", [
      { label: resolvedTheme === "dark" ? "Switch to Light Theme" : "Switch to Dark Theme", action: () => setTheme(resolvedTheme === "dark" ? "light" : "dark") },
      { label: "Search / Command Palette", action: () => openCommandPalette() },
    ]),
    menu("Insert", [
      { label: "New Load", href: "/loads/new" },
      { label: "New Dispatch", href: "/dispatch/new" },
      "separator",
      { label: "New Carrier", href: "/carriers/new" },
      { label: "Invite Carrier (Onboarding)", href: "/carriers/onboarding/invite" },
      { label: "New Driver", href: "/drivers/new" },
      { label: "New Truck", href: "/trucks/new" },
      { label: "New Trailer", href: "/trailers/new" },
      { label: "New Broker", href: "/brokers/new" },
      { label: "New Customer", href: "/customers/new" },
      "separator",
      { label: "New Invoice", href: "/invoices/new" },
      { label: "New Dispatch Fee Invoice", href: "/dispatch-fee-invoices/new" },
      { label: "Record Payment", href: "/payments/new" },
      { label: "New Carrier Settlement", href: "/settlements/new" },
      { label: "New Driver Settlement", href: "/driver-settlements/new" },
      { label: "Add Advance", href: "/advances/new" },
      { label: "New Expense", href: "/expenses/new" },
    ]),
    menu("Tools", [
      { label: "Factoring Companies", href: "/settings/factoring" },
      { label: "Integrations", href: "/settings/integrations" },
      { label: "Email & Sending Domain", href: "/settings/email" },
      { label: "Email History", href: "/email-history" },
      { label: "Bank Accounts", href: "/settings/organization/bank-accounts" },
      { label: "Subscription", href: "/settings/subscription" },
    ]),
    menu("Reports", [
      { label: "Revenue", href: "/reports/revenue" },
      { label: "Accounts Receivable Aging", href: "/reports/accounts-receivable" },
      "separator",
      { label: "Profitability", href: "/reports/profitability" },
      { label: "Profit by Carrier", href: "/reports/profit-by-carrier" },
      { label: "Profit by Broker", href: "/reports/profit-by-broker" },
      { label: "Profit by Driver", href: "/reports/profit-by-driver" },
      { label: "Load Margin", href: "/reports/load-margin" },
      { label: "Lane Profitability", href: "/reports/lane-profitability" },
      "separator",
      { label: "Carrier Performance", href: "/reports/carrier-performance" },
      { label: "Broker Performance", href: "/reports/broker-performance" },
      "separator",
      { label: "Carrier Pay", href: "/reports/carrier-pay" },
      { label: "Driver Pay", href: "/reports/driver-pay" },
      { label: "Expenses", href: "/reports/expenses" },
    ]),
    menu("Window", [
      { label: "Dashboard", href: "/dashboard" },
      "separator",
      { label: "Dispatch Board", href: "/dispatch/board" },
      { label: "Loads", href: "/loads" },
      { label: "Live Tracking", href: "/tracking" },
      { label: "Exception Center", href: "/dispatch/exceptions" },
      "separator",
      { label: "Carriers", href: "/carriers" },
      { label: "Drivers", href: "/drivers" },
      { label: "Brokers", href: "/brokers" },
      { label: "Customers", href: "/customers" },
      "separator",
      { label: "Billing Overview", href: "/billing" },
      { label: "Ready to Bill", href: "/billing/ready-to-bill" },
      { label: "Invoices", href: "/invoices" },
      { label: "Dispatch Fee Invoices", href: "/dispatch-fee-invoices" },
      { label: "Payments", href: "/payments" },
      { label: "Accounts Receivable", href: "/accounts-receivable" },
      { label: "Collections", href: "/collections" },
      { label: "Statements", href: "/statements" },
      "separator",
      { label: "Carrier Settlements", href: "/settlements" },
      { label: "Driver Settlements", href: "/driver-settlements" },
    ]),
    menu("Help", [
      { label: "Search & Keyboard Shortcuts", action: () => openCommandPalette() },
      { label: "My Profile", href: "/settings/profile" },
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
            {visibleItems(m.items, role).map((item, idx) =>
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
