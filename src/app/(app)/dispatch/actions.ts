"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { updateRecordInPlace, getCurrentOrgId } from "@/lib/actions/records";
import { requireOperationalAccess } from "@/lib/billing/operational-access";
import { emptyToNull, toNumber } from "@/lib/utils/form";
import { DispatchConflictError, translateDispatchError, type DispatchActionState } from "@/lib/dispatch/errors";
import { computeOperationalTimestampUpdates } from "@/lib/dispatch/operational-timestamps";
import {
  ACTIVE_DISPATCH_STATUSES,
  classifyAssignmentConflict,
  conflictMessage,
  CONFLICT_CODE,
  DISPATCH_MAINTENANCE_CODE,
  DISPATCH_MAINTENANCE_MESSAGE,
  LOAD_ALREADY_DISPATCHED_CODE,
  rpcDispatchConflict,
  type AssignmentConflict,
  type ClassifyParams,
  type ConflictResource,
  type DispatchLite,
} from "@/lib/dispatch/conflicts";

const UNIQUE_INDEX_FIELD: Record<string, ConflictResource> = {
  dispatches_active_driver_unique: "driver",
  dispatches_active_truck_unique: "truck",
  dispatches_active_trailer_unique: "trailer",
};

// Fetch every ACTIVE dispatch that touches this load / driver / truck /
// trailer, in ONE query, then let src/lib/dispatch/conflicts.ts decide.
// The `loads` embed is disambiguated (`loads!dispatches_load_id_fkey`) --
// since migration 0125 added loads.financial_dispatch_id -> dispatches.id
// there are TWO dispatches<->loads relationships and a bare `loads(...)`
// embed returns PGRST201, which the previous code silently read as "no
// conflict". `error` is now surfaced, never swallowed.
async function fetchConflictCandidates(
  supabase: Awaited<ReturnType<typeof createClient>>,
  params: ClassifyParams
): Promise<DispatchLite[]> {
  const ors: string[] = [
    `driver_id.eq.${params.driverId}`,
    `truck_id.eq.${params.truckId}`,
  ];
  if (params.loadId) ors.push(`load_id.eq.${params.loadId}`);
  if (params.trailerId) ors.push(`trailer_id.eq.${params.trailerId}`);

  const { data, error } = await supabase
    .from("dispatches")
    .select(
      "id, status, load_id, driver_id, truck_id, trailer_id, loads:loads!dispatches_load_id_fkey(load_number), drivers(first_name, last_name), trucks(unit_number), trailers(unit_number)"
    )
    .in("status", ACTIVE_DISPATCH_STATUSES)
    .or(ors.join(","));

  if (error) {
    // A failed availability lookup must NEVER read as "available". Surface
    // it as an unexpected error (the outer catch logs full detail + shows
    // the generic "couldn't save" message); the 0054 unique indexes still
    // hard-block a real clash on INSERT regardless.
    throw new Error(`dispatch conflict lookup failed: ${error.message}`);
  }

  return ((data ?? []) as unknown as Array<{
    id: string;
    status: string;
    load_id: string;
    driver_id: string | null;
    truck_id: string | null;
    trailer_id: string | null;
    loads: { load_number: string } | null;
    drivers: { first_name: string; last_name: string } | null;
    trucks: { unit_number: string } | null;
    trailers: { unit_number: string } | null;
  }>).map((r) => ({
    id: r.id,
    status: r.status,
    load_id: r.load_id,
    load_number: r.loads?.load_number ?? null,
    driver_id: r.driver_id,
    truck_id: r.truck_id,
    trailer_id: r.trailer_id,
    driver_name: r.drivers ? `${r.drivers.first_name} ${r.drivers.last_name}` : null,
    truck_unit: r.trucks?.unit_number ?? null,
    trailer_unit: r.trailers?.unit_number ?? null,
  }));
}

function toDispatchConflictError(c: AssignmentConflict): DispatchConflictError {
  if (c.kind === "load_already_dispatched") {
    return new DispatchConflictError(conflictMessage(c), {
      code: LOAD_ALREADY_DISPATCHED_CODE,
      field: null,
      conflictDispatchId: c.dispatchId,
    });
  }
  return new DispatchConflictError(conflictMessage(c), {
    code: CONFLICT_CODE[c.resource],
    field: c.resource,
    conflictDispatchId: c.dispatchId,
    conflictLoadNumber: c.loadNumber,
  });
}

export async function updateDispatchStatus(id: string, status: string) {
  await updateRecordInPlace("dispatches", id, { status }, "/dispatch/board");
}

// ---------------------------------------------------------------------------
// Conflict detection (spec section 11): a load that already has an active
// dispatch, or a driver/truck/trailer already tied to another ACTIVE
// dispatch, is a hard block -- none of them can be in two places at once.
// Reads only dispatches.status; no fabricated availability engine. The
// canonical rule lives in src/lib/dispatch/conflicts.ts and is shared,
// verbatim, by the fast pre-check here AND by raceLoserConflict()'s
// re-derivation after a 0054 partial-unique-index rejection -- so the
// frontend never sees two different verdicts. excludeDispatchId lets an
// edit skip self-conflict.
//
// This is the fast pre-check, not the sole guarantee -- it's a plain
// SELECT-then-INSERT and can race. The 0054 partial unique indexes are the
// authoritative backstop; createDispatch/updateDispatch translate a race
// that slips past into the same message shape, never a raw DB error.
// ---------------------------------------------------------------------------
async function checkAssignmentConflicts(
  supabase: Awaited<ReturnType<typeof createClient>>,
  params: { loadId?: string; driverId: string; truckId: string; trailerId: string | null; excludeDispatchId?: string }
) {
  const candidates = await fetchConflictCandidates(supabase, params);
  const conflict = classifyAssignmentConflict(candidates, params);
  if (conflict) throw toDispatchConflictError(conflict);
}

// Out-of-service equipment (spec section 6). getAssignmentOptions() already
// filters dropdowns to status='active' trucks/trailers, so this is mainly a
// staleness/direct-request guard (the truck went out of service after the
// page loaded, or a crafted request skipped the dropdown) -- but it's a
// real, reachable path, not a hypothetical one, so it gets the same
// professional-message treatment as an assignment conflict rather than
// falling through to a DB error.
async function checkEquipmentAvailable(
  supabase: Awaited<ReturnType<typeof createClient>>,
  params: { truckId: string; trailerId: string | null }
) {
  const { truckId, trailerId } = params;

  const { data: truck } = await supabase.from("trucks").select("id, unit_number, status").eq("id", truckId).maybeSingle();
  if (truck && truck.status !== "active") {
    const { data: mr } = await supabase
      .from("maintenance_records")
      .select("id")
      .eq("truck_id", truckId)
      .eq("status", "open")
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    throw new DispatchConflictError(`Truck ${truck.unit_number} is currently out of service for maintenance and cannot be dispatched.`, {
      code: "TRUCK_OUT_OF_SERVICE",
      field: "truck",
      maintenanceId: mr?.id ?? null,
    });
  }

  if (trailerId) {
    const { data: trailer } = await supabase.from("trailers").select("id, unit_number, status").eq("id", trailerId).maybeSingle();
    if (trailer && trailer.status !== "active") {
      const { data: mr } = await supabase
        .from("maintenance_records")
        .select("id")
        .eq("trailer_id", trailerId)
        .eq("status", "open")
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();
      throw new DispatchConflictError(`Trailer ${trailer.unit_number} is currently out of service for maintenance and cannot be dispatched.`, {
        code: "TRAILER_OUT_OF_SERVICE",
        field: "trailer",
        maintenanceId: mr?.id ?? null,
      });
    }
  }
}

// A 0054 unique_violation slipped past the pre-check (a genuine concurrent
// race). Re-derive the exact same rich conflict -- who actually holds the
// slot now -- rather than surfacing "duplicate key value violates unique
// constraint...". If that re-lookup somehow comes up empty (the winner's
// own dispatch was cancelled/edited in the instant between the failed
// insert and this query), still return an expected conflict, never fall
// through to the raw DB error.
async function raceLoserConflict(
  supabase: Awaited<ReturnType<typeof createClient>>,
  indexName: string,
  values: { driver_id: string; truck_id: string; trailer_id: string | null },
  excludeDispatchId?: string
): Promise<DispatchConflictError> {
  const field = UNIQUE_INDEX_FIELD[indexName];
  const candidates = await fetchConflictCandidates(supabase, {
    driverId: values.driver_id,
    truckId: values.truck_id,
    trailerId: values.trailer_id,
    excludeDispatchId,
  });
  const conflict = classifyAssignmentConflict(candidates, {
    driverId: values.driver_id,
    truckId: values.truck_id,
    trailerId: values.trailer_id,
    excludeDispatchId,
  });
  if (conflict) return toDispatchConflictError(conflict);
  // The winner's own dispatch was cancelled/edited in the instant between
  // the failed insert and this re-lookup -- still an expected "someone else
  // just took this" conflict, never the raw DB error.
  return new DispatchConflictError("This assignment was just taken by another dispatch. Please review and choose different equipment/driver.", {
    code: "CONCURRENT_UPDATE",
    field,
  });
}

function matchedUniqueIndex(message: string | undefined): string | null {
  if (!message) return null;
  for (const name of Object.keys(UNIQUE_INDEX_FIELD)) {
    if (message.includes(name)) return name;
  }
  return null;
}

// Phase 2G.10 writer cutover: dispatch_fee_percentage and notes are no
// longer part of the dispatches insert/update -- they're written to
// dispatch_financials/dispatch_internal_notes by writeDispatchFinancials()/
// writeDispatchNotes() below, in the SAME action, right after the
// dispatches row's id is known. Kept in the return shape here (still read
// by checkEquipmentAvailable/checkAssignmentConflicts callers below, which
// only use carrier_id/truck_id/driver_id/trailer_id) for minimal diff, but
// never written to `dispatches` directly anymore -- see createDispatch/
// updateDispatch.
function dispatchValues(formData: FormData) {
  const carrierId = String(formData.get("carrier_id") || "").trim();
  const truckId = String(formData.get("truck_id") || "").trim();
  const driverId = String(formData.get("driver_id") || "").trim();
  if (!carrierId) throw new Error("Carrier is required.");
  if (!truckId) throw new Error("Truck is required.");
  if (!driverId) throw new Error("Driver is required.");
  return {
    carrier_id: carrierId,
    truck_id: truckId,
    driver_id: driverId,
    trailer_id: emptyToNull(formData.get("trailer_id")),
  };
}

// NOTE: requires 0067 applied (dispatch_financials/dispatch_internal_notes
// must exist) -- ships in the same deploy as 0067/0068, never before.
async function writeDispatchFinancials(supabase: Awaited<ReturnType<typeof createClient>>, dispatchId: string, organizationId: string, formData: FormData) {
  const dispatchFeePercentage = toNumber(formData.get("dispatch_fee_percentage")) ?? 10;
  // load_rate/dispatch_fee_amount/carrier_net_amount are computed by
  // dispatch_financials_sync (0068), the same way sync_dispatch_financials()
  // always computed them -- only dispatch_fee_percentage is a real user
  // input here.
  const { error } = await supabase
    .from("dispatch_financials")
    .upsert({ dispatch_id: dispatchId, organization_id: organizationId, dispatch_fee_percentage: dispatchFeePercentage }, { onConflict: "dispatch_id" });
  if (error) throw new Error(error.message);
}

async function writeDispatchNotes(supabase: Awaited<ReturnType<typeof createClient>>, dispatchId: string, organizationId: string, formData: FormData) {
  const notes = emptyToNull(formData.get("notes"));
  const { error } = await supabase
    .from("dispatch_internal_notes")
    .upsert({ dispatch_id: dispatchId, organization_id: organizationId, notes }, { onConflict: "dispatch_id" });
  if (error) throw new Error(error.message);
}

// Status is intentionally NOT part of dispatchValues(): createDispatch
// always hardcodes 'assigned' for a brand-new dispatch (a status field on
// the create form would be meaningless before it exists), while
// updateDispatch reads it from the form separately, below.
function statusValue(formData: FormData): string {
  const status = String(formData.get("status") || "").trim();
  return status || "assigned";
}

// Bespoke rather than the generic insertRecord() helper: this also flips
// the load's status to "dispatched" in the same action, and insertRecord's
// redirect() would abort before that second write ever ran.
//
// useActionState-compatible (spec section 2): expected business conflicts
// (assignment conflicts, out-of-service equipment, cross-carrier
// mismatches, a lost concurrency race) are returned as a DispatchActionState,
// never thrown into the route error boundary. redirect() is called only
// after every fallible step has already succeeded, outside the try/catch,
// so its internal Next.js control-flow signal is never mistaken for an
// error to translate.
export async function createDispatch(_prevState: DispatchActionState, formData: FormData): Promise<DispatchActionState> {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  // Fail-closed kill switch (0129 rollback plan): set DISPATCH_WRITES_DISABLED=1
  // in the environment to pause dispatch creation/cancellation ONLY. The
  // board, load records, edits, tracking and every other operation stay up.
  // Default unset/off. No redirect happens on this path, so the Create
  // button never looks successful.
  if (process.env.DISPATCH_WRITES_DISABLED === "1") {
    return { error: DISPATCH_MAINTENANCE_MESSAGE, code: DISPATCH_MAINTENANCE_CODE };
  }
  const loadId = String(formData.get("load_id") || "").trim();
  const supabase = await createClient();

  let newDispatchId: string;
  try {
    if (!loadId) throw new Error("Select a load first.");
    const values = dispatchValues(formData);

    // Pre-flight -- fast, specific UX feedback BEFORE the RPC round trip.
    // Not authoritative: create_dispatch (0129) re-checks everything inside
    // one transaction and is the real guarantee.
    await checkEquipmentAvailable(supabase, { truckId: values.truck_id, trailerId: values.trailer_id });
    await checkAssignmentConflicts(supabase, { loadId, driverId: values.driver_id, truckId: values.truck_id, trailerId: values.trailer_id });

    // 0129: one atomic transaction -- dispatch + financials + notes +
    // loads.status='dispatched' + financial_dispatch_id + activity log, all
    // or nothing. organization_id is derived DB-side from the load; never
    // sent from here.
    const { data, error } = await supabase.rpc("create_dispatch", {
      p_load_id: loadId,
      p_carrier_id: values.carrier_id,
      p_truck_id: values.truck_id,
      p_driver_id: values.driver_id,
      p_trailer_id: values.trailer_id,
      p_dispatch_fee_percentage: toNumber(formData.get("dispatch_fee_percentage")) ?? null,
      p_notes: emptyToNull(formData.get("notes")),
    });
    if (error) {
      const c = rpcDispatchConflict(error);
      if (c) {
        throw new DispatchConflictError(c.message, {
          code: c.code,
          field: c.field,
          conflictDispatchId: c.conflictDispatchId,
        });
      }
      // guard_dispatch_org() (0055) cross-org / cross-carrier RAISE, or any
      // other DB error -- translated, never a raw string to the user.
      throw error;
    }
    newDispatchId = data as string;
  } catch (err) {
    return translateDispatchError(err);
  }

  revalidatePath("/dispatch/board");
  revalidatePath(`/loads/${loadId}`);
  redirect(`/dispatch/${newDispatchId}`);
}

// Plain update -- same row, same id, no duplicate ever created. Re-runs the
// same conflict + org/relationship + equipment-availability checks (the DB
// guard trigger fires on UPDATE too) since the assignment can change on an
// edit exactly like on create. Same useActionState/expected-error
// convention as createDispatch.
export async function updateDispatch(id: string, _prevState: DispatchActionState, formData: FormData): Promise<DispatchActionState> {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();

  try {
    const organizationId = await getCurrentOrgId();
    const values = dispatchValues(formData);
    const status = statusValue(formData);

    await checkEquipmentAvailable(supabase, { truckId: values.truck_id, trailerId: values.trailer_id });
    await checkAssignmentConflicts(supabase, {
      driverId: values.driver_id,
      truckId: values.truck_id,
      trailerId: values.trailer_id,
      excludeDispatchId: id,
    });

    // Phase 2I.1: this full-edit-form path is the OTHER real way a
    // dispatch can reach status='delivered'/'completed' (the Dispatch
    // Board's own drag/drop, updateDispatchBoardStatus(), already applied
    // this bookkeeping) -- confirmed live to have been the actual cause
    // of 3 dispatches reaching a delivered-like status with delivered_at
    // left null (see the Phase 2I.1 pre-migration report's audit trail).
    // Same shared, idempotent rule as the board move -- never overwrites
    // a timestamp that's already set, applied to whichever ONE of the
    // five 0057 columns this specific status transition (if any) owns.
    const { data: priorRow } = await supabase
      .from("dispatches")
      .select("status, en_route_pickup_at, loaded_at, in_transit_at, delivered_at, cancelled_at")
      .eq("id", id)
      .maybeSingle();
    const previousStatus = priorRow?.status ?? null;
    const nowIso = new Date().toISOString();
    const timestampUpdates = priorRow ? computeOperationalTimestampUpdates(status, priorRow, nowIso) : {};

    const { error } = await supabase
      .from("dispatches")
      .update({ ...values, status, ...timestampUpdates })
      .eq("id", id);
    if (error) {
      const indexName = matchedUniqueIndex(error.message);
      if (error.code === "23505" && indexName) {
        throw await raceLoserConflict(supabase, indexName, values, id);
      }
      throw error;
    }

    // Phase 2G.10: same split as createDispatch above.
    await writeDispatchFinancials(supabase, id, organizationId, formData);
    await writeDispatchNotes(supabase, id, organizationId, formData);

    // Phase 2I.1: capture the actual status transition when one happened,
    // same shape updateDispatchBoardStatus() already logs -- previously
    // this call always passed p_changes: null unconditionally, which is
    // exactly why no historical log row from this path could ever prove
    // WHEN a status change happened (see the pre-migration report). Still
    // logs on every save (not only status changes), matching this
    // action's own prior "updated" semantics for anyone watching the
    // Activity section for non-status edits.
    await supabase.rpc("log_activity", {
      p_entity_type: "dispatch",
      p_entity_id: id,
      p_action: "updated",
      p_changes: previousStatus && previousStatus !== status ? { field: "status", old_value: previousStatus, new_value: status } : null,
      p_organization_id: organizationId,
    });
  } catch (err) {
    return translateDispatchError(err);
  }

  revalidatePath("/dispatch/board");
  revalidatePath(`/dispatch/${id}`);
  redirect(`/dispatch/${id}`);
}

// ---------------------------------------------------------------------------
// Cancel (spec section 13) -- replaces the old hard-delete button.
// load_tracking_events.dispatch_id is ON DELETE CASCADE (0004): a hard
// delete would have silently destroyed every location/status ping ever
// recorded for this dispatch. Every other FK to dispatches (advances,
// expenses, driver/carrier settlement items) is ON DELETE SET NULL --
// those rows would have survived a delete but lost which dispatch they
// came from. 'cancelled' already exists on dispatch_status (0001) and is
// already handled everywhere dispatch status is read (the board excludes
// cancelled from its active/net totals) -- no new status invented.
// The load is reverted to 'booked' so it becomes re-dispatchable, but
// ONLY if it hasn't progressed past dispatch on its own (mirrors the same
// guard sync_load_status_from_dispatch() (0028) already uses, so this
// never regresses a load a delivery/invoice/close has already moved past).
// ---------------------------------------------------------------------------
export async function cancelDispatch(id: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  // Same fail-closed kill switch as createDispatch. Thrown (this action is
  // not useActionState-wrapped) but as the structured DispatchConflictError
  // shape, with the DISPATCH_MAINTENANCE code -- no redirect, so Cancel
  // never looks successful.
  if (process.env.DISPATCH_WRITES_DISABLED === "1") {
    throw new DispatchConflictError(DISPATCH_MAINTENANCE_MESSAGE, { code: DISPATCH_MAINTENANCE_CODE });
  }
  const reason = emptyToNull(formData.get("reason"));
  const supabase = await createClient();

  // load_id only for revalidation of the load page afterward (read-only).
  const { data: dispatch } = await supabase.from("dispatches").select("load_id").eq("id", id).maybeSingle();

  // 0129: one atomic transaction -- idempotent when already cancelled,
  // refuses delivered/completed, sets status + reason note + cancelled_at,
  // returns the load to booked only when no OTHER active dispatch holds it
  // and it hasn't moved past delivery, and logs. Financial history
  // (financial_dispatch_id / dispatch_financials / notes) is left intact.
  const { error } = await supabase.rpc("cancel_dispatch", { p_dispatch_id: id, p_reason: reason });
  if (error) {
    const c = rpcDispatchConflict(error);
    throw new Error(c?.message ?? error.message ?? "Could not cancel this dispatch.");
  }

  revalidatePath("/dispatch/board");
  revalidatePath(`/dispatch/${id}`);
  if (dispatch?.load_id) revalidatePath(`/loads/${dispatch.load_id}`);
  redirect(`/dispatch/${id}`);
}
