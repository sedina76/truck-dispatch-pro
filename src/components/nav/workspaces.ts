// Workspaces: related pages shown as tabs under one sidebar entry. Pure
// (no React, no icons) so it can be shared by the sidebar, the tab row and
// tests.

/**
 * Related pages shown as tabs inside one sidebar entry. Every page keeps its
 * own address; the tab row (WorkspaceTabs) appears on any page under one of
 * the tabs. Billing keeps its own BillingSubnav and is not listed here.
 */
export type WorkspaceTab = { label: string; href: string; match?: string[] };
export const WORKSPACES: { key: string; tabs: WorkspaceTab[] }[] = [
  { key: "dispatch", tabs: [{ label: "Dispatch Board", href: "/dispatch/board", match: ["/dispatch/board", "/dispatch/new"] }, { label: "Exception Center", href: "/dispatch/exceptions" }] },
  { key: "drivers", tabs: [{ label: "Drivers", href: "/drivers" }, { label: "Driver Applications", href: "/drivers/applications" }] },
  { key: "equipment", tabs: [{ label: "Trucks", href: "/trucks" }, { label: "Trailers", href: "/trailers" }] },
  { key: "maintenance", tabs: [{ label: "Maintenance", href: "/maintenance" }, { label: "Fuel Logs", href: "/fuel" }] },
  { key: "carriers", tabs: [{ label: "Carriers", href: "/carriers" }, { label: "Carrier Onboarding", href: "/carriers/onboarding" }] },
  { key: "partners", tabs: [{ label: "Brokers", href: "/brokers" }, { label: "Customers", href: "/customers" }] },
  {
    key: "pay",
    tabs: [
      { label: "Expenses", href: "/expenses" },
      { label: "Advances", href: "/advances" },
      { label: "Carrier Settlements", href: "/settlements" },
      { label: "Driver Settlements", href: "/driver-settlements" },
    ],
  },
  { key: "documents", tabs: [{ label: "Documents", href: "/documents" }, { label: "Compliance", href: "/compliance" }] },
  { key: "reports", tabs: [{ label: "Reports", href: "/reports" }, { label: "Email History", href: "/email-history" }] },
  {
    key: "settings",
    tabs: [
      { label: "Organization", href: "/settings/organization" },
      { label: "Users", href: "/settings/users" },
      { label: "Email & Sending Domain", href: "/settings/email" },
      { label: "Factoring Companies", href: "/settings/factoring" },
      { label: "Integrations", href: "/settings/integrations" },
      { label: "Subscription", href: "/settings/subscription" },
    ],
  },
];

const under = (path: string, p: string) => path === p || path.startsWith(p + "/");

/** The tab a path belongs to (longest match wins, so /drivers/applications is not "Drivers"). */
export function workspaceFor(pathname: string): { tabs: WorkspaceTab[]; active: string } | null {
  let best: { tabs: WorkspaceTab[]; active: string; len: number } | null = null;
  for (const w of WORKSPACES) {
    for (const t of w.tabs) {
      for (const p of t.match ?? [t.href]) {
        if (under(pathname, p) && (!best || p.length > best.len)) best = { tabs: w.tabs, active: t.href, len: p.length };
      }
    }
  }
  return best && { tabs: best.tabs, active: best.active };
}

/** Is this sidebar item the current place? */
export function navItemActive(item: { href: string; match?: string[] }, pathname: string): boolean {
  if (item.href === "/dashboard") return pathname === "/dashboard";
  return (item.match ?? [item.href]).some((p) => under(pathname, p));
}

