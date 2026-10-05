import {
  LayoutDashboard,
  KanbanSquare,
  Package,
  Truck,
  Building2,
  UserRound,
  Container,
  Wrench,
  FileText,
  Receipt,
  Wallet,
  BarChart3,
  Settings,
  LifeBuoy,
  Radio,
  CalendarDays,
  ShieldAlert,
  FolderOpen,
} from "lucide-react";

// Phase 2G.6: pulled out of sidebar.tsx so the new mobile nav (bottom bar +
// drawer) can share the EXACT same section/role data instead of hand
// -maintaining a second copy that could silently drift from the desktop
// sidebar -- the two navs must always agree about what exists and who can
// see it.
export { WORKSPACES, workspaceFor, navItemActive, type WorkspaceTab } from "./workspaces";

export type OrgRole = "owner" | "admin" | "dispatcher" | "accountant" | "driver" | "viewer";
export const ALL_ROLES: OrgRole[] = ["owner", "admin", "dispatcher", "accountant", "driver", "viewer"];

export type NavItem = { label: string; href: string; icon: React.ComponentType<{ className?: string }>; roles?: OrgRole[]; /** Paths that also highlight this item (its workspace tabs). */ match?: string[] };
export type NavSection = { title: string; items: NavItem[]; roles?: OrgRole[] };

// Every route BillingSubnav links to (src/components/desktop/billing-subnav.tsx).
export const BILLING_WORKSPACE_PREFIXES = ["/billing", "/invoices", "/carrier-invoices", "/payments", "/accounts-receivable", "/collections", "/statements"];

// Phase 2G.5 -- consolidated per the Master Product Consolidation review.
// Every route below already existed before that pass; only the GROUPING
// and the item COUNT changed. What used to be a 13-item "Accounting"
// section is now a single "Billing" entry -- Invoices, Payments,
// Statements, Accounts Receivable, and Collections did not move or lose
// their own top-level routes, they now live inside the Billing
// workspace's own internal subnav (BillingSubnav, rendered by each of
// those pages) instead of consuming five permanent sidebar rows.
// "Promises to Pay"/"Disputes"/"Reminders" were removed here entirely
// (not moved) -- they never had dedicated pages, only routed into
// Collections with a query param; that's still true and still reachable
// from inside Collections itself, so nothing was lost, only a redundant
// nav entry.
//
// Settlements/Driver Settlements/Advances/Expenses stay OUTSIDE the
// Billing group deliberately: they're outbound money (paying carriers and
// drivers), not the inbound customer/broker billing (AR) workflow Billing
// represents -- a real, existing distinction in this schema (separate
// tables, separate RLS story), not an arbitrary split.
//
// ROLE VISIBILITY is UX-only. It mirrors, but does not replace, the real
// RLS/server-side role checks (0010_rls_policies.sql,
// 0066_financial_rls_hardening.sql, and the requireRole()/requireRoleForApi()
// page guards in src/lib/auth/require-role.ts) -- hiding a link here never
// becomes the security boundary. See each section's `roles` for the
// specific reasoning; the Billing/Reports/Communications/Administration
// tiers below are the exact same FINANCIAL_ROLES tier require-role.ts
// exports, so nav visibility and real page authorization can never
// disagree about who sees what.
export const SECTIONS: NavSection[] = [
  {
    title: "Command Center",
    items: [{ label: "Dashboard", href: "/dashboard", icon: LayoutDashboard }],
  },
  {
    title: "Operations",
    items: [
      // Exception Center is a tab inside the Dispatch workspace (WORKSPACES below).
      { label: "Dispatch Board", href: "/dispatch/board", icon: KanbanSquare, match: ["/dispatch"] },
      { label: "Loads", href: "/loads", icon: Package },
      { label: "Live Tracking", href: "/tracking", icon: Radio },
      { label: "Schedule", href: "/schedule", icon: CalendarDays },
    ],
  },
  {
    title: "Fleet",
    items: [
      { label: "Drivers", href: "/drivers", icon: UserRound },
      { label: "Equipment", href: "/trucks", icon: Truck, match: ["/trucks", "/trailers"] },
      { label: "Maintenance & Fuel", href: "/maintenance", icon: Wrench, match: ["/maintenance", "/fuel"] },
      { label: "Safety", href: "/safety", icon: ShieldAlert, roles: ["owner", "admin", "dispatcher", "accountant", "viewer"] },
    ],
  },
  {
    title: "Partners",
    items: [
      { label: "Carriers", href: "/carriers", icon: Container },
      { label: "Brokers & Customers", href: "/brokers", icon: Building2, match: ["/brokers", "/customers"] },
    ],
  },
  {
    title: "Money",
    // Same tier as FINANCIAL_ROLES in src/lib/auth/require-role.ts.
    roles: ["owner", "admin", "dispatcher", "accountant"],
    items: [
      { label: "Billing", href: "/billing", icon: Receipt, match: BILLING_WORKSPACE_PREFIXES },
      // Dispatch company -> carrier: dispatch fees plus advances, fuel and
      // repairs the dispatch company paid. Billing roles only.
      { label: "Dispatch Fee Invoices", href: "/dispatch-fee-invoices", icon: FileText, roles: ["owner", "admin", "accountant"] },
      // Carrier Settlements, Driver Settlements, Advances and Expenses are
      // tabs inside this one workspace.
      { label: "Pay & Expenses", href: "/expenses", icon: Wallet, match: ["/expenses", "/advances", "/settlements", "/driver-settlements"] },
    ],
  },
  {
    title: "Records",
    items: [
      { label: "Documents", href: "/documents", icon: FolderOpen, match: ["/documents", "/compliance"] },
      { label: "Reports", href: "/reports", icon: BarChart3, roles: ["owner", "admin", "dispatcher", "accountant"], match: ["/reports", "/email-history"] },
    ],
  },
  {
    title: "Settings",
    items: [
      { label: "Settings", href: "/settings/organization", icon: Settings, roles: ["owner", "admin"], match: ["/settings/organization", "/settings/users", "/settings/email", "/settings/integrations", "/settings/subscription", "/settings/factoring"] },
      { label: "Help", href: "/settings/profile", icon: LifeBuoy, roles: ALL_ROLES },
    ],
  },
];

// Shared by both Sidebar and MobileNavDrawer -- an item's own `roles`
// overrides its section's; a section only disappears once every one of
// its items is filtered out.
export function visibleSections(role: OrgRole): NavSection[] {
  return SECTIONS.map((section) => ({
    ...section,
    items: section.items.filter((item) => (item.roles ?? section.roles ?? ALL_ROLES).includes(role)),
  })).filter((section) => section.items.length > 0);
}
