"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { updateRecordInPlace, getCurrentOrgId } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";
import { DispatchConflictError, translateDispatchError, type DispatchActionState } from "@/lib/dispatch/errors";

// Same "in progress" set the Driver Portal uses for its own current-trip
// resolver (src/lib/driver-portal/dashboard-data.ts, ACTIVE_DISPATCH_
// STATUSES) -- duplicated here rather than imported so this staff-side
// module never reaches into driver-portal internals. Used for the
// dashboard/board, the conflict checks below, AND the partial unique
// indexes in 0054_dispatch_conflict_guards.sql -- if this list ever
// changes, that migration's WHERE clauses must change with it.
const ACTIVE_DISPATCH_STATUSES = [
  "assigned",
  "accepted",
  "en_route_to_pickup",
  "at_pickup",
  "loaded",
  "en_route_to_delivery",
  "at_delivery",
] as const;

// One index name -> field mapping, shared between the pre-check's own
// lookups and the concurrency-backstop re-derivation after a 0054 unique-
// violation.
const CONFLICT_CODE: Record<"driver" | "truck" | "trailer", string> = {
  driver: "DRIVER_ACTIVE_DISPATCH",
  truck: "TRUCK_ACTIVE_DISPATCH",
  trailer: "TRAILER_ACTIVE_DISPATCH",
};
const CONFLICT_LABEL: Record<"driver" | "truck" | "trailer", string> = {
  driver: "This driver",
  truck: "This truck",
  trailer: "This trailer",
};
const UNIQUE_INDEX_FIELD: Record<string, "driver" | "truck" | "trailer"> = {
  dispatches_active_driver_unique: "driver",
  dispatches_active_truck_unique: "truck",
  dispatches_active_trailer_unique: "trailer",
};

export async function updateDispatchStatus(id: string, status: string) {
  await updateRecordInPlace("dispatches", id, { status }, "/dispatch/board");
}

// Looks up whichever OTHER dispatch currently holds this driver/truck/
// trailer active, if any. Shared by the pre-check (checkAssignment
// Conflicts) and the concurrency-backstop re-derivation (after a 0054
// unique_violation) so both paths produce the exact same message shape.
async function findActiveConflict(
  supabase: Awaited<ReturnType<typeof createClient>>,
  field: "driver" | "truck" | "trailer",
  value: string,
  excludeDispatchId?: string
): Promise<{ dispatchId: string; loadNumber: string | null } | null> {
  const column = field === "driver" ? "driver_id" : field === "truck" ? "truck_id" : "trailer_id";
  let query = supabase.from("dispatches").select("id, loads(load_number)").eq(column, value).in("status", ACTIVE_DISPATCH_STATUSES);
  if (excludeDispatchId) query = query.neq("id", excludeDispatchId);
  const { data } = await query.limit(1).maybeSingle();
  const row = data as unknown as { id: string; loads: { load_number: string } | null } | null;
  if (!row) return null;
  return { dispatchId: row.id, loadNumber: row.loads?.load_number ?? null };
}

function conflictError(field: "driver" | "truck" | "trailer", hit: { dispatchId: string; loadNumber: string | null }): DispatchConflictError {
  const loadRef = hit.loadNumber ? `load ${hit.loadNumber}` : "another active dispatch";
  return new DispatchConflictError(`${CONFLICT_LABEL[field]} is already assigned to active ${loadRef}.`, {
    code: CONFLICT_CODE[field],
    field,
    conflictDispatchId: hit.dispatchId,
    conflictLoadNumber: hit.loadNumber,
  });
}

// ---------------------------------------------------------------------------
// Conflict detection (spec section 11): a driver/truck/trailer already tied
// to another ACTIVE dispatch is a hard block, not a soft warning -- none of
// the three can physically be in two places at once. Reads only
// dispatches.status, real scheduling data this schema already has; no
// fabricated availability engine. excludeDispatchId lets editing a dispatch
// without changing its driver/truck/trailer skip self-conflict.
//
// This is the fast pre-check, not the sole guarantee -- it's a plain
// SELECT-then-INSERT and can race with a concurrent request. The 0054
// partial unique indexes are the actual authoritative backstop; see
// createDispatch/updateDispatch's error handling for how a race that slips
// past this check still comes back as the same kind of message, never a
// raw DB error.
// ---------------------------------------------------------------------------
async function checkAssignmentConflicts(
  supabase: Awaited<ReturnType<typeof createClient>>,
  params: { driverId: string; truckId: string; trailerId: string | null; excludeDispatchId?: string }
) {
  const { driverId, truckId, trailerId, excludeDispatchId } = params;

  const driverConflict = await findActiveConflict(supabase, "driver", driverId, excludeDispatchId);
  if (driverConflict) throw conflictError("driver", driverConflict);

  const truckConflict = await findActiveConflict(supabase, "truck", truckId, excludeDispatchId);
  if (truckConflict) throw conflictError("truck", truckConflict);

  if (trailerId) {
    const trailerConflict = await findActiveConflict(supabase, "trailer", trailerId, excludeDispatchId);
    if (trailerConflict) throw conflictError("trailer", trailerConflict);
  }
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
  const value = field === "driver" ? values.driver_id : field === "truck" ? values.truck_id : values.trailer_id;
  const hit = value ? await findActiveConflict(supabase, field, value, excludeDispatchId) : null;
  if (hit) return conflictError(field, hit);
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
    dispatch_fee_percentage: toNumber(formData.get("dispatch_fee_percentage")) ?? 10,
    notes: emptyToNull(formData.get("notes")),
  };
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
  const loadId = String(formData.get("load_id") || "").trim();
  const supabase = await createClient();

  let newDispatchId: string;
  try {
    if (!loadId) throw new Error("Select a load first.");
    const organizationId = await getCurrentOrgId();
    const values = dispatchValues(formData);

    await checkEquipmentAvailable(supabase, { truckId: values.truck_id, trailerId: values.trailer_id });
    await checkAssignmentConflicts(supabase, { driverId: values.driver_id, truckId: values.truck_id, trailerId: values.trailer_id });

    const { data, error } = await supabase
      .from("dispatches")
      .insert({ organization_id: organizationId, load_id: loadId, status: "assigned", ...values })
      .select("id")
      .single();
    if (error) {
      // guard_dispatch_org() (0048) raises a clear, specific message for any
      // cross-org or cross-carrier mismatch -- translated, not swallowed.
      // A 0054 unique_violation means a concurrent request won the race
      // between this action's own pre-check and this insert.
      const indexName = matchedUniqueIndex(error.message);
      if (error.code === "23505" && indexName) {
        throw await raceLoserConflict(supabase, indexName, values);
      }
      throw error;
    }
    newDispatchId = data.id;

    await supabase.from("loads").update({ status: "dispatched" }).eq("id", loadId);
    await supabase.rpc("log_activity", { p_entity_type: "dispatch", p_entity_id: newDispatchId, p_action: "created", p_changes: null, p_organization_id: organizationId });
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

    const { error } = await supabase.from("dispatches").update({ ...values, status }).eq("id", id);
    if (error) {
      const indexName = matchedUniqueIndex(error.message);
      if (error.code === "23505" && indexName) {
        throw await raceLoserConflict(supabase, indexName, values, id);
      }
      throw error;
    }

    await supabase.rpc("log_activity", { p_entity_type: "dispatch", p_entity_id: id, p_action: "updated", p_changes: null, p_organization_id: organizationId });
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
  const reason = emptyToNull(formData.get("reason"));
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  const { data: dispatch } = await supabase.from("dispatches").select("load_id, status, notes").eq("id", id).single();
  if (!dispatch) throw new Error("Dispatch not found.");
  if (dispatch.status === "cancelled") {
    redirect(`/dispatch/${id}`);
  }

  // Append, never overwrite -- the existing internal dispatch notes are
  // not replaced just because this dispatch is being cancelled.
  const cancelNote = `[Cancelled${reason ? `: ${reason}` : ""}]`;
  const newNotes = dispatch.notes ? `${dispatch.notes}\n${cancelNote}` : cancelNote;

  const { error } = await supabase.from("dispatches").update({ status: "cancelled", notes: newNotes }).eq("id", id);
  if (error) throw new Error(error.message);

  await supabase
    .from("loads")
    .update({ status: "booked" })
    .eq("id", dispatch.load_id)
    .not("status", "in", "(delivered,pod_received,invoiced,closed,cancelled)");

  await supabase.rpc("log_activity", {
    p_entity_type: "dispatch",
    p_entity_id: id,
    p_action: "cancelled",
    p_changes: reason ? { reason } : null,
    p_organization_id: organizationId,
  });

  revalidatePath("/dispatch/board");
  revalidatePath(`/dispatch/${id}`);
  revalidatePath(`/loads/${dispatch.load_id}`);
  redirect(`/dispatch/${id}`);
}
