// Who may use the money pages (invoices, payments, statements, carrier and
// driver settlements): owner, admin, accountant -- exactly the roles the
// database lets write there (RLS on invoices/payments/settlements/
// statements, 0010). Dispatchers keep loads, dispatch, POD, advances and
// rates; they no longer see billing screens they could open but not save.
// Shared by server guards (require-role.ts) and client menus.

export const BILLING_ROLES = ["owner", "admin", "accountant"] as const;

const BILLING_ONLY_PREFIXES = ["/invoices", "/payments", "/statements", "/settlements", "/driver-settlements", "/dispatch-fee-invoices"];

export function isBillingOnlyHref(href: string): boolean {
  const path = href.split(/[?#]/)[0];
  return BILLING_ONLY_PREFIXES.some((p) => path === p || path.startsWith(p + "/"));
}

export function canUseBilling(role: string | null | undefined): boolean {
  return !!role && (BILLING_ROLES as readonly string[]).includes(role);
}

/** Menus: hide billing-only destinations from roles that cannot use them. */
export function hrefAllowedForRole(href: string, role: string | null | undefined): boolean {
  return !isBillingOnlyHref(href) || canUseBilling(role);
}
