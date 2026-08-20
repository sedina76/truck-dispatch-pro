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

// The exact PostgREST `.or()` fragment the board query filters on --
// isolated here so the query and every display helper below share the
// identical cutoff instant for a single request (computed once, not
// re-derived slightly differently in two places).
export function boardRetentionOrFilter(now: Date = new Date()): string {
  const cutoff = new Date(now.getTime() - DELIVERED_RETENTION_HOURS * 60 * 60 * 1000).toISOString();
  // Three independent reasons a row survives the filter, matching the
  // approved design exactly:
  //   1. not delivered-like at all -- still an active operational status.
  //   2. delivered_at is unexpectedly null -- FAIL OPEN, never silently
  //      hide a row just because its timestamp bookkeeping is missing
  //      (see the Part A2 migration/report for why this can still
  //      theoretically happen even after the write-side fix).
  //   3. delivered_at is within the retention window.
  return `status.not.in.(delivered,completed),delivered_at.is.null,delivered_at.gte.${cutoff}`;
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
