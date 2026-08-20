// Phase 2I.1 -- the ONE shared definition of "when a dispatch's status
// changes, which 0057 operational timestamp column (if any) gets stamped,
// and only if it isn't already set" (idempotent -- a dispatch that
// bounces back into a status it already reached once never overwrites
// the original moment). Originally inline only inside
// updateDispatchBoardStatus() (board-actions.ts); pulled out here so
// updateDispatch() (the full edit-form path, dispatch/actions.ts) can
// apply the EXACT same bookkeeping instead of skipping it entirely, which
// is what actually caused 3 live dispatches to reach delivered/completed
// with delivered_at left null (see the Phase 2I.1 pre-migration report
// for the live audit trail). Both callers still do their own read-prior/
// write-update around this -- this function only computes WHAT to write.
export type OperationalTimestamps = {
  en_route_pickup_at?: string | null;
  loaded_at?: string | null;
  in_transit_at?: string | null;
  delivered_at?: string | null;
  cancelled_at?: string | null;
};

// 'delivered' AND 'completed' both stamp delivered_at -- the Dispatch
// Board's own drag/drop can only ever produce 'delivered' (see
// kanban-board.tsx's COLUMNS config, dropStatus: "delivered"), but the
// full edit form's status field can also produce 'completed' directly,
// and that transition deserves the identical delivered_at bookkeeping,
// matching DELIVERED_LIKE_STATUSES' own treatment of the two statuses as
// equivalent everywhere else in this app (board/page.tsx, board-
// actions.ts's own DELIVERED_LIKE_STATUSES, kanban-board.tsx).
export function computeOperationalTimestampUpdates(
  newStatus: string,
  prior: OperationalTimestamps,
  nowIso: string
): Partial<Record<keyof OperationalTimestamps, string>> {
  const updates: Partial<Record<keyof OperationalTimestamps, string>> = {};
  switch (newStatus) {
    case "en_route_to_pickup":
      if (!prior.en_route_pickup_at) updates.en_route_pickup_at = nowIso;
      break;
    case "loaded":
      if (!prior.loaded_at) updates.loaded_at = nowIso;
      break;
    case "en_route_to_delivery":
      if (!prior.in_transit_at) updates.in_transit_at = nowIso;
      break;
    case "delivered":
    case "completed":
      if (!prior.delivered_at) updates.delivered_at = nowIso;
      break;
    case "cancelled":
      if (!prior.cancelled_at) updates.cancelled_at = nowIso;
      break;
    // assigned/accepted: no dedicated timestamp column -- dispatched_at
    // already covers "assigned" (see 0057's own migration comment).
  }
  return updates;
}
