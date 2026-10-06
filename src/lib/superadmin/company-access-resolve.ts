import { resolveBillingAccess } from "@/lib/billing/access-policy";
import { describeAccess, toBillingFacts, type CompanyAccess, type CompanyAccessFacts } from "@/lib/superadmin/company-access";

/** A company's real access state, from the same resolver the middleware uses. */
export function companyAccess(f: CompanyAccessFacts): CompanyAccess {
  return describeAccess(resolveBillingAccess(toBillingFacts(f)), f);
}
