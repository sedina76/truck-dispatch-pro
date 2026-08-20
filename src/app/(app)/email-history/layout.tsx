import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

// Guards /email-history -- internal correspondence with brokers/customers
// (billing packets, invoice sends, collections reminders) is office-only
// per the Financial Data Rule's "internal email history" line item.
export default async function EmailHistoryLayout({ children }: { children: React.ReactNode }) {
  await requireRole(FINANCIAL_ROLES);
  return <>{children}</>;
}
