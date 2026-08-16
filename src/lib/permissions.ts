// Mirrors the RLS role tiers in supabase/migrations/0010_rls_policies.sql.
// This is a UI convenience for hiding actions a role can't perform -- the
// database RLS policies are the actual enforcement layer, not this file.
export type OrgRole = "owner" | "admin" | "dispatcher" | "accountant" | "driver" | "viewer";

const OPERATIONAL_WRITE: OrgRole[] = ["owner", "admin", "dispatcher"];
const FINANCIAL_WRITE: OrgRole[] = ["owner", "admin", "accountant"];
const ADMIN_ONLY: OrgRole[] = ["owner", "admin"];

export const permissions = {
  manageFleetAndPartners: (role: OrgRole) => OPERATIONAL_WRITE.includes(role),
  manageLoadsAndDispatch: (role: OrgRole) => OPERATIONAL_WRITE.includes(role),
  manageInvoicesAndSettlements: (role: OrgRole) => FINANCIAL_WRITE.includes(role),
  logCosts: (role: OrgRole) => FINANCIAL_WRITE.includes(role) || role === "dispatcher",
  deleteRecords: (role: OrgRole) => ADMIN_ONLY.includes(role),
  manageUsers: (role: OrgRole) => ADMIN_ONLY.includes(role),
  manageIntegrationsAndBilling: (role: OrgRole) => ADMIN_ONLY.includes(role),
  manageOrganizationProfile: (role: OrgRole) => role === "owner",
};
