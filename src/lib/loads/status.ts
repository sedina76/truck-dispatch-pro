// Single canonical definition of what "active" and "completed" mean for a
// load, used by every KPI, chart, and metric in the app that counts loads
// or trips by status. Before this existed, three different files each
// defined their own "active" status set and two different "completed"
// definitions -- meaning the same load could count as active on one page
// and not another. Everything that buckets loads by status must import
// from here rather than declaring its own list.
//
// public.load_status enum (0001_extensions_enums_helpers.sql):
//   draft, posted, booked, dispatched, in_transit, at_pickup, at_delivery,
//   delivered, pod_received, invoiced, closed, cancelled, problem

// Booked but not yet assigned to a carrier/truck/driver -- tracked as its
// own KPI ("Loads Pending Dispatch") on the dashboard, so deliberately NOT
// included in ACTIVE below (a load can't be both "pending dispatch" and
// "active" at the same time under one consistent model).
export const PENDING_DISPATCH_LOAD_STATUSES = ["booked"] as const;

// Dispatched and moving, but not yet delivered.
export const ACTIVE_LOAD_STATUSES = ["dispatched", "in_transit", "at_pickup", "at_delivery"] as const;

// Physically delivered. Includes pod_received (paperwork confirmation of
// the same physical delivery event) but deliberately NOT invoiced/closed --
// those are downstream accounting states of an already-completed trip, not
// a different delivery outcome, so a trip doesn't stop being "completed"
// the moment it's invoiced.
export const COMPLETED_LOAD_STATUSES = ["delivered", "pod_received"] as const;

// Downstream accounting states, reached only after COMPLETED_LOAD_STATUSES.
// Broken out as its own bucket (e.g. for the dashboard's status donut)
// rather than folded into "Delivered", so that bucket's count always
// matches COMPLETED_LOAD_STATUSES exactly.
export const INVOICED_LOAD_STATUSES = ["invoiced", "closed"] as const;

export const CANCELLED_LOAD_STATUS = "cancelled";

// Every load that is still open work for an operator -- booked-but-unassigned
// PLUS dispatched-and-moving -- but not yet delivered/invoiced/cancelled.
// This is the set the /loads list's "Active" KPI counts, so a freshly booked
// load is visibly in flight there the moment it exists (it was previously
// invisible: counted as neither Active nor Delivered).
//
// Deliberately SEPARATE from ACTIVE_LOAD_STATUSES: the dashboard keeps
// "Active Loads" (ACTIVE_LOAD_STATUSES, via isActiveLoadStatus) and "Loads
// Pending Dispatch" (booked) as two distinct KPIs and must not double-count,
// so nothing that already uses ACTIVE_LOAD_STATUSES / isActiveLoadStatus
// changes -- only callers that explicitly want "open work including booked"
// use this.
export const OPEN_LOAD_STATUSES = [
  ...PENDING_DISPATCH_LOAD_STATUSES,
  ...ACTIVE_LOAD_STATUSES,
] as const;

export function isActiveLoadStatus(status: string): boolean {
  return (ACTIVE_LOAD_STATUSES as readonly string[]).includes(status);
}

export function isOpenLoadStatus(status: string): boolean {
  return (OPEN_LOAD_STATUSES as readonly string[]).includes(status);
}

export function isCompletedLoadStatus(status: string): boolean {
  return (COMPLETED_LOAD_STATUSES as readonly string[]).includes(status);
}
