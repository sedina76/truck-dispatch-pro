// Who may use the money pages (invoices, payments, statements, carrier and
// driver settlements): owner, admin, accountant -- exactly the roles the
// database lets write there (RLS on invoices/payments/settlements/
// statements, 0010). Dispatchers keep loads, dispatch, POD, advances and
// rates; they no longer see billing screens they could open but not save.
// Shared by server guards (require-role.ts) and client menus.

export const BILLING_ROLES = ["owner", "admin", "accountant"] as const;

const BILLING_ONLY_PREFIXES = ["/invoices", "/payments", "/statements", "/settlements", "/driver-settlements", "/dispatch-fee-invoices", "/carrier-invoices"];

export function isBillingOnlyHref(href: string): boolean {
  const path = href.split(/[?#]/)[0];
  return BILLING_ONLY_PREFIXES.some((p) => path === p || path.startsWith(p + "/"));
}

export function canUseBilling(role: string | null | undefined): boolean {
  return !!role && (BILLING_ROLES as readonly string[]).includes(role);
}

// Office money/report areas every staff role but driver/viewer may open
// (FINANCIAL_ROLES in require-role.ts guards these pages), and the
// owner/admin-only administration pages (the sidebar's Administration
// section). Used only to keep menus from offering pages a role can't open.
const FINANCIAL_ROLE_LIST = ["owner", "admin", "dispatcher", "accountant"];
const FINANCIAL_PREFIXES = ["/billing", "/reports", "/accounts-receivable", "/collections", "/expenses", "/advances", "/email-history", "/settings/factoring"];
const ADMIN_PREFIXES = ["/settings/users", "/settings/organization", "/settings/integrations", "/settings/email", "/settings/subscription"];

const under = (path: string, prefixes: string[]) => prefixes.some((p) => path === p || path.startsWith(p + "/"));

/** Menus: hide destinations a role cannot open (billing-only, financial, admin). */
export function hrefAllowedForRole(href: string, role: string | null | undefined): boolean {
  const path = href.split(/[?#]/)[0];
  if (isBillingOnlyHref(path)) return canUseBilling(role);
  if (under(path, FINANCIAL_PREFIXES)) return !!role && FINANCIAL_ROLE_LIST.includes(role);
  if (under(path, ADMIN_PREFIXES)) return role === "owner" || role === "admin";
  return true;
}
