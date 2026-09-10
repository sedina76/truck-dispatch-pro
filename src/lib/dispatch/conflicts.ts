// Canonical assignment-conflict rules for the Dispatch create/edit actions.
// Pure -- no Supabase, no network. actions.ts fetches the candidate active
// dispatch rows (with the disambiguated `loads!dispatches_load_id_fkey`
// embed -- see WHY below) and hands them here, so "is this load already
// dispatched / is this driver/truck/trailer busy" is decided in ONE place,
// used identically by the fast pre-check and by the post-INSERT backstop
// that re-derives a message after a 0054 partial-unique-index rejection.
//
// WHY the embed must be disambiguated: migration 0125 added
// loads.financial_dispatch_id -> dispatches.id, so PostgREST now sees TWO
// relationships between `dispatches` and `loads`. A bare `.select("...,
// loads(load_number)")` then fails with PGRST201 and returns
// { data: null, error }, which the old code read as "no conflict found" --
// silently disabling every driver/truck/trailer availability check and
// turning a genuine clash into the generic "assignment just changed"
// message. The fix is naming the FK; this module exists so the rule can be
// regression-tested without a live DB.

// The dispatch_status values that mean "this dispatch is holding its driver/
// truck/trailer right now". MUST stay in sync with the WHERE clauses of the
// three partial unique indexes in
// supabase/migrations/0054_dispatch_conflict_guards.sql -- those indexes are
// the hard guarantee on INSERT; this list is the app-side mirror.
export const ACTIVE_DISPATCH_STATUSES = [
  "assigned",
  "accepted",
  "en_route_to_pickup",
  "at_pickup",
  "loaded",
  "en_route_to_delivery",
  "at_delivery",
] as const;

// Terminal / non-holding statuses, listed only for clarity + tests:
// 'delivered', 'completed', 'cancelled' -- a dispatch in any of these never
// blocks a new assignment.
export function isActiveDispatchStatus(status: string): boolean {
  return (ACTIVE_DISPATCH_STATUSES as readonly string[]).includes(status);
}

export type ConflictResource = "driver" | "truck" | "trailer";

// The shape actions.ts maps each fetched dispatch row into before calling
// classifyAssignmentConflict(). `load_number` / *_unit / driver_name come
// from the (disambiguated) embeds; null when the embed row is absent.
export type DispatchLite = {
  id: string;
  status: string;
  load_id: string;
  load_number: string | null;
  driver_id: string | null;
  truck_id: string | null;
  trailer_id: string | null;
  driver_name: string | null;
  truck_unit: string | null;
  trailer_unit: string | null;
};

export type AssignmentConflict =
  | { kind: "load_already_dispatched"; dispatchId: string; loadNumber: string | null }
  | {
      kind: "resource_busy";
      resource: ConflictResource;
      dispatchId: string;
      loadNumber: string | null;
      resourceLabel: string;
    };

export type ClassifyParams = {
  /** Present for create (the load being dispatched); omit for edit -- an
   *  existing dispatch never "duplicates" its own load. */
  loadId?: string;
  driverId: string;
  truckId: string;
  trailerId: string | null;
  /** Editing a dispatch: ignore that same row (self-conflict). */
  excludeDispatchId?: string;
};

/**
 * First conflict wins, in the order: this load already has an active
 * dispatch -> driver busy -> truck busy -> trailer busy. Only ACTIVE
 * statuses are considered; the excluded dispatch (edit case) is dropped.
 */
export function classifyAssignmentConflict(
  candidateDispatches: DispatchLite[],
  params: ClassifyParams
): AssignmentConflict | null {
  const rows = candidateDispatches.filter(
    (d) => isActiveDispatchStatus(d.status) && d.id !== params.excludeDispatchId
  );

  if (params.loadId) {
    const dup = rows.find((d) => d.load_id === params.loadId);
    if (dup) {
      return { kind: "load_already_dispatched", dispatchId: dup.id, loadNumber: dup.load_number };
    }
  }

  const driver = params.driverId ? rows.find((d) => d.driver_id === params.driverId) : undefined;
  if (driver) {
    return {
      kind: "resource_busy",
      resource: "driver",
      dispatchId: driver.id,
      loadNumber: driver.load_number,
      resourceLabel: driver.driver_name ?? "This driver",
    };
  }

  const truck = params.truckId ? rows.find((d) => d.truck_id === params.truckId) : undefined;
  if (truck) {
    return {
      kind: "resource_busy",
      resource: "truck",
      dispatchId: truck.id,
      loadNumber: truck.load_number,
      resourceLabel: truck.truck_unit ? `Truck ${truck.truck_unit}` : "This truck",
    };
  }

  if (params.trailerId) {
    const trailer = rows.find((d) => d.trailer_id === params.trailerId);
    if (trailer) {
      return {
        kind: "resource_busy",
        resource: "trailer",
        dispatchId: trailer.id,
        loadNumber: trailer.load_number,
        resourceLabel: trailer.trailer_unit ? `Trailer ${trailer.trailer_unit}` : "This trailer",
      };
    }
  }

  return null;
}

export const CONFLICT_CODE: Record<ConflictResource, string> = {
  driver: "DRIVER_ACTIVE_DISPATCH",
  truck: "TRUCK_ACTIVE_DISPATCH",
  trailer: "TRAILER_ACTIVE_DISPATCH",
};

export const LOAD_ALREADY_DISPATCHED_CODE = "LOAD_ALREADY_DISPATCHED";

// 0129 fail-closed kill switch: when DISPATCH_WRITES_DISABLED=1, create /
// cancel return/throw this instead of touching the RPC.
export const DISPATCH_MAINTENANCE_CODE = "DISPATCH_MAINTENANCE";
export const DISPATCH_MAINTENANCE_MESSAGE =
  "Creating and cancelling dispatches is paused for maintenance. The Dispatch Board, load records, edits, and tracking are unaffected -- please try again shortly.";

/** User-facing message. Dispatches carry no scheduled end time in this
 *  schema, so a resource conflict names the resource + the load it is on,
 *  not an "until <time>". */
export function conflictMessage(c: AssignmentConflict): string {
  if (c.kind === "load_already_dispatched") {
    return "This load already has an active dispatch. Open it from the Dispatch Board to make changes, or cancel that dispatch first.";
  }
  const loadRef = c.loadNumber ? `load ${c.loadNumber}` : "another active dispatch";
  return `${c.resourceLabel} is already assigned to active ${loadRef}.`;
}

// ---------------------------------------------------------------------------
// 0129 atomic RPC error translation.
//
// public.create_dispatch / public.cancel_dispatch RAISE with a 5-char
// SQLSTATE (TDxxx), a user-safe MESSAGE (the exact copy to show), and --
// for the resource/load conflicts -- DETAIL = the conflicting dispatch id.
// supabase-js surfaces this as { code, message, details, hint }. This maps
// it back onto the SAME DispatchConflictError shape the UX pre-flight uses,
// so the RPC (authoritative) and the pre-flight never show two different
// messages for the same situation.
// ---------------------------------------------------------------------------
export type RpcLikeError =
  | { code?: string | null; message?: string | null; details?: string | null }
  | null
  | undefined;

const RPC_CODE_MAP: Record<string, { appCode: string; field: ConflictResource | null }> = {
  TDDUP: { appCode: LOAD_ALREADY_DISPATCHED_CODE, field: null }, // load already has an active dispatch (or an unresolved 0054 race)
  TDDRV: { appCode: CONFLICT_CODE.driver, field: "driver" },
  TDTRK: { appCode: CONFLICT_CODE.truck, field: "truck" },
  TDTRL: { appCode: CONFLICT_CODE.trailer, field: "trailer" },
  TDLND: { appCode: "LOAD_NOT_DISPATCHABLE", field: null },
  TDLNF: { appCode: "LOAD_NOT_FOUND", field: null },
  TDCNF: { appCode: "DISPATCH_NOT_FOUND", field: null },
  TDTRM: { appCode: "DISPATCH_TERMINAL", field: null },
  TDROL: { appCode: "forbidden", field: null },
  TDAUT: { appCode: "not_authenticated", field: null },
};

export type RpcDispatchConflict = {
  message: string;
  code: string;
  field: ConflictResource | null;
  conflictDispatchId: string | null;
};

/** Returns a translated conflict, or null when `err` is not a recognised
 *  0129 RPC error (caller then falls back to its generic handling). */
export function rpcDispatchConflict(err: RpcLikeError): RpcDispatchConflict | null {
  const code = err?.code ?? undefined;
  if (!code || !RPC_CODE_MAP[code]) return null;
  const mapped = RPC_CODE_MAP[code];
  const detail = (err?.details ?? "").trim();
  const isUuid = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(detail);
  return {
    message: (err?.message ?? "").trim() || "Could not save this dispatch. Please try again.",
    code: mapped.appCode,
    field: mapped.field,
    conflictDispatchId: isUuid ? detail : null,
  };
}
