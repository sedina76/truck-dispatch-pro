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
  HandCoins,
  ReceiptText,
  BarChart3,
  Mail,
  Plug,
  Inbox,
  UserPlus,
  UserCog,
  Settings,
  Landmark,
  LifeBuoy,
  AlertTriangle,
  Radio,
  Banknote,
} from "lucide-react";

// Phase 2G.6: pulled out of sidebar.tsx so the new mobile nav (bottom bar +
// drawer) can share the EXACT same section/role data instead of hand
// -maintaining a second copy that could silently drift from the desktop
// sidebar -- the two navs must always agree about what exists and who can
// see it.
export type OrgRole = "owner" | "admin" | "dispatcher" | "accountant" | "driver" | "viewer";
export const ALL_ROLES: OrgRole[] = ["owner", "admin", "dispatcher", "accountant", "driver", "viewer"];

export type NavItem = { label: string; href: string; icon: React.ComponentType<{ className?: string }>; roles?: OrgRole[] };
export type NavSection = { title: string; items: NavItem[]; roles?: OrgRole[] };

// Every route BillingSubnav links to (src/components/desktop/billing-subnav.tsx).
export const BILLING_WORKSPACE_PREFIXES = ["/billing", "/invoices", "/payments", "/accounts-receivable", "/collections", "/statements"];

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
      { label: "Dispatch Board", href: "/dispatch/board", icon: KanbanSquare },
      { label: "Loads", href: "/loads", icon: Package },
      { label: "Live Tracking", href: "/tracking", icon: Radio },
      { label: "Exception Center", href: "/dispatch/exceptions", icon: AlertTriangle },
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
    title: "Business",
    items: [
      { label: "Customers", href: "/customers", icon: Users },
      { label: "Brokers", href: "/brokers", icon: Building2 },
      { label: "Carriers", href: "/carriers", icon: Truck },
    ],
  },
  {
    title: "Billing",
    // Same access tier the invoices/settlements RLS insert/update/delete
    // policies already require (owner/admin/accountant), plus dispatcher
    // -- dispatchers are the ones moving loads to Delivered, so they're
    // the ones who most need to see Ready to Bill. Matches FINANCIAL_ROLES
    // in src/lib/auth/require-role.ts exactly.
    roles: ["owner", "admin", "dispatcher", "accountant"],
    items: [
      { label: "Billing", href: "/billing", icon: Receipt },
      // Phase 2H.8: the OPERATIONAL factoring workspace (portfolio KPIs,
      // work queues, factor exposure) -- distinct from Settings ->
      // Factoring below (configuration only: companies/relationships/
      // terms/default factor), exactly as that item's own comment always
      // anticipated. Same FINANCIAL_ROLES tier as every other item here
      // (inherited from the section, no per-item override needed).
      { label: "Factoring", href: "/factoring", icon: Banknote },
      { label: "Carrier Settlements", href: "/settlements", icon: HandCoins },
      { label: "Driver Settlements", href: "/driver-settlements", icon: UserRound },
      { label: "Advances", href: "/advances", icon: Wallet },
      { label: "Expenses", href: "/expenses", icon: ReceiptText },
    ],
  },
  {
    title: "Documents & Compliance",
    items: [
      { label: "Documents", href: "/documents", icon: FileText },
      { label: "Compliance", href: "/compliance", icon: ShieldCheck },
    ],
  },
  {
    title: "Reports",
    roles: ["owner", "admin", "dispatcher", "accountant"],
    items: [{ label: "Reports", href: "/reports", icon: BarChart3 }],
  },
  {
    title: "Communications",
    roles: ["owner", "admin", "dispatcher", "accountant"],
    items: [{ label: "Email History", href: "/email-history", icon: Inbox }],
  },
  {
    title: "Administration",
    roles: ["owner", "admin"],
    items: [
      { label: "Users", href: "/settings/users", icon: UserCog },
      { label: "Settings", href: "/settings/organization", icon: Settings },
      // Phase 2H.3: configuration/master-data only (factoring companies +
      // commercial relationships) -- deliberately visible to the same
      // FINANCIAL_ROLES tier as Billing, not the section's own
      // owner/admin-only default (an item's own `roles` overrides its
      // section's, same override mechanism "Help" below already uses).
      // The operational Factoring workspace (submitting invoices, funding,
      // reserve release) is a separate, later Phase 2H checkpoint and does
      // NOT live here.
      { label: "Factoring", href: "/settings/factoring", icon: Landmark, roles: ["owner", "admin", "dispatcher", "accountant"] },
      { label: "Email & Sending Domain", href: "/settings/email", icon: Mail },
      { label: "Integrations", href: "/settings/integrations", icon: Plug },
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
