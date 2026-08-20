import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

// Guards the OFFICE driver-settlements module (/driver-settlements,
// /driver-settlements/new, /driver-settlements/[id], and the nested
// /driver-settlements/[id]/pdf page.tsx print-view). This is a
// completely separate system from the Driver Portal (driver_portal_sessions,
// service-role only, no relationship to profiles.role/RLS at all -- see
// src/lib/driver-portal/session.ts) -- a driver-role STAFF account must
// still go through the Driver Portal's own safe path to see their own pay,
// per the Financial Data Rule; this office view is never the way, even
// for a driver looking at only their own record.
export default async function DriverSettlementsLayout({ children }: { children: React.ReactNode }) {
  await requireRole(FINANCIAL_ROLES);
  return <>{children}</>;
}
