// Phase 2I.1 -- the ONE shared definition of the Dispatch Board's 24-hour
// delivered-retention rule, used by both the board query (server, decides
// what's actually fetched) and every display surface (drawer banner,
// board card) that needs to say the same thing about the same dispatch.
// Query-level filtering only -- nothing here ever mutates a dispatch row
// or archives anything; a dispatch that "clears the board" is simply no
// longer selected by the query in board/page.tsx, still fully reachable
// everywhere else (Load Detail, Billing, Invoices, Reports, Driver
// history, Driver Portal).
//
// Hard-coded default (spec Part A6: "Do not build full retention
// configuration unless trivial... For this phase: hard default = 24
// hours"). Kept as one named constant so a future per-org setting has a
// single place to originate from, without pretending that configuration
// exists yet.
import { formatStopDateTime } from "@/lib/timezone/format";

export const DELIVERED_RETENTION_HOURS = 24;
const DELIVERED_LIKE_STATUSES = new Set(["delivered", "completed"]);

// REVISION (completed-dispatch retention workflow): 'cancelled' now
// follows the identical 24-hour rule, keyed off cancelled_at instead of
// delivered_at -- previously this filter's own "not delivered-like"
// branch (`status.not.in.(delivered,completed)`) meant a cancelled
// dispatch matched unconditionally and NEVER left the active board,
// regardless of age. That was a real gap relative to the desired
// behavior (delivered/completed and cancelled should both clear the
// active board after 24h), not a deliberate design choice -- fixed here,
// in the ONE shared place both statuses' rules are expressed, rather
// than adding a second, parallel filter definition elsewhere.
export const TERMINAL_STATUSES = new Set(["delivered", "completed", "cancelled"]);

// The exact PostgREST `.or()` fragment the board query filters on --
// isolated here so the query and every display helper below share the
// identical cutoff instant for a single request (computed once, not
// re-derived slightly differently in two places). Uses PostgREST's
// nested and()-within-or() syntax (documented, standard filter grammar)
// since delivered/completed and cancelled each need their OWN timestamp
// column compared against the SAME cutoff -- a flat comma-separated list
// of column.op.value conditions can't express "this status AND this
// column" pairing on its own.
export function boardRetentionOrFilter(now: Date = new Date()): string {
  const cutoff = new Date(now.getTime() - DELIVERED_RETENTION_HOURS * 60 * 60 * 1000).toISOString();
  // Five independent reasons a row survives the filter:
  //   1. not a terminal status at all -- still an active operational status.
  //   2/3. delivered-like (delivered/completed), with delivered_at either
  //      unexpectedly null (FAIL OPEN -- never silently hide a row just
  //      because its timestamp bookkeeping is missing; see this
  //      migration's own report for the one currently-known write path
  //      that could historically produce this, now fixed) or within the
  //      retention window.
  //   4/5. cancelled, with the identical null-fails-open / within-window
  //      treatment, keyed off cancelled_at instead.
  return [
    `status.not.in.(${[...TERMINAL_STATUSES].join(",")})`,
    `and(status.in.(delivered,completed),delivered_at.is.null)`,
    `and(status.in.(delivered,completed),delivered_at.gte.${cutoff})`,
    `and(status.eq.cancelled,cancelled_at.is.null)`,
    `and(status.eq.cancelled,cancelled_at.gte.${cutoff})`,
  ].join(",");
}

// The logical complement of boardRetentionOrFilter() above -- rows that
// are CURRENTLY hidden from the default board by the 24-hour rule (never
// rows with a missing timestamp, which fail open and are therefore never
// "hidden" by this rule in the first place). Used only for a lightweight
// count (requirement: "preserve a separate historical/completed count"),
// never to actually fetch/display rows -- kept in this one file so it can
// never drift from the rule it's the mirror image of.
export function boardHiddenByRetentionFilter(now: Date = new Date()): string {
  const cutoff = new Date(now.getTime() - DELIVERED_RETENTION_HOURS * 60 * 60 * 1000).toISOString();
  return [
    `and(status.in.(delivered,completed),delivered_at.not.is.null,delivered_at.lt.${cutoff})`,
    `and(status.eq.cancelled,cancelled_at.not.is.null,cancelled_at.lt.${cutoff})`,
  ].join(",");
}

// Same rule, evaluated in JS for a single already-fetched row -- used by
// the drawer (which has one row, already loaded, and needs to decide
// what to show/say) rather than re-querying. Must stay logically
// identical to boardRetentionOrFilter() above; both are exported from
// this one file specifically so they can never drift apart.
export function isWithinActiveRetention(status: string, deliveredAt: string | null, now: Date = new Date()): boolean {
  if (!DELIVERED_LIKE_STATUSES.has(status)) return true;
  if (!deliveredAt) return true; // fail open, same reasoning as the query
  const cutoff = now.getTime() - DELIVERED_RETENTION_HOURS * 60 * 60 * 1000;
  return new Date(deliveredAt).getTime() >= cutoff;
}

export type RetentionCountdown = {
  expired: boolean;
  remainingMs: number;
  /** "22h 47m" */
  compact: string;
  /** "Leaves active board tomorrow at 4:32 PM CT" (or today, using the given timezone) */
  sentence: string;
};

// Display-only -- the actual source of truth is always the query filter
// above; this never gates anything, it only describes the same rule in
// words. Countdown math is plain duration arithmetic on the already-
// correct UTC delivered_at instant -- the only place a timezone matters
// is rendering the clears-at WALL-CLOCK moment, which goes through the
// app's own existing formatStopDateTime() (never a second timezone
// implementation).
export function deliveredRetentionCountdown(deliveredAt: string, timezone: string, now: Date = new Date()): RetentionCountdown {
  const clearsAtMs = new Date(deliveredAt).getTime() + DELIVERED_RETENTION_HOURS * 60 * 60 * 1000;
  const remainingMs = clearsAtMs - now.getTime();
  const clearsAtIso = new Date(clearsAtMs).toISOString();

  if (remainingMs <= 0) {
    return { expired: true, remainingMs: 0, compact: "Cleared from active board", sentence: "No longer on the active Dispatch Board." };
  }

  const totalMinutes = Math.floor(remainingMs / 60_000);
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  const compact = hours > 0 ? `${hours}h ${minutes}m` : `${minutes}m`;

  return {
    expired: false,
    remainingMs,
    compact,
    sentence: `Leaves active board ${formatStopDateTime(clearsAtIso, timezone)}`,
  };
}
