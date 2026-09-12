"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { requireOperationalAccess } from "@/lib/billing/operational-access";
import { emptyToNull, toNumber } from "@/lib/utils/form";
import { DispatchConflictError, translateDispatchError, type DispatchActionState } from "@/lib/dispatch/errors";
import { buildReassignmentIdempotencyKey } from "@/lib/dispatch/reassignment-idempotency";
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
  type DispatchLite,
} from "@/lib/dispatch/conflicts";


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

// Phase 3A.1 hotfix (item E, "search the entire repository for every direct
// dispatch status mutation"): this export has NO caller anywhere in the
// codebase today (grep-confirmed) -- dead code, not part of the reproduced
// deadlock's reachable risk class. Left in place (a future caller may start
// using it) but fixed rather than removed: it used to do a raw
// `updateRecordInPlace("dispatches", id, { status }, ...)`, the SAME
// unguarded pattern (no transition-matrix check, no lock-order guarantee,
// no role/reason check for reactivation) that board-actions.ts and this
// file's own updateDispatch() were fixed to stop using. Routed through the
// same authoritative RPC so it can never become a live, unguarded
// reactivation path if it is ever wired up later.
//
// requireOperationalAccess() is called explicitly here, not inherited: the
// old body's only write was updateRecordInPlace(...), which gates
// internally; replacing it with a direct .rpc() call would otherwise have
// silently DROPPED the D.2.11 billing gate this export always had (caught
// by operational-access.test.mjs's D.2.11 #27 static check, not merely
// theoretical -- confirmed failing before this line was added, passing
// after).
export async function updateDispatchStatus(id: string, status: string) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const { error } = await supabase.rpc("transition_dispatch_status", { p_dispatch_id: id, p_new_status: status });
  if (error) {
    const conflict = rpcDispatchConflict(error);
    throw conflict ? new DispatchConflictError(conflict.message, { code: conflict.code, field: conflict.field }) : error;
  }
  revalidatePath("/dispatch/board");
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

// Phase 3A.2 (item 3): a 0054 unique_violation slipped past the pre-check
// used to be re-derived here (raceLoserConflict/matchedUniqueIndex) for
// updateDispatch()'s old direct-UPDATE path. That path is gone -- driver/
// truck/trailer reassignment now goes through public.reassign_dispatch_
// resources() (0135), which translates its OWN 0054 unique_violation race
// internally (RRDRV/RRTRK/RRTRL, with the conflicting dispatch id as
// DETAIL) via rpcDispatchConflict() below, exactly like createDispatch()
// already relies on create_dispatch() (0129) to do the same for TDDRV/
// TDTRK/TDTRL. A raw 23505 no longer needs to be caught and re-derived
// client-side for ANY dispatch write path in this file.

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
// the create form would be meaningless before it exists). Phase 3A.4 (item
// 2) removed status editing from updateDispatch() entirely -- status
// transitions are now exclusively a Dispatch Board / dedicated-action
// concern (transition_dispatch_status(), 0134, via board-actions.ts) -- so
// there is no longer a corresponding helper here at all.

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

// Phase 3A.2 (item 1): fields the generic dispatch edit form may change.
// carrier_id is DELIBERATELY EXCLUDED -- a dispatch's carrier can never be
// changed through this ordinary form (see updateDispatch below for the
// explicit tamper/staleness check, and dispatch/[id]/page.tsx for the
// now-read-only Carrier field).
function updateDispatchResourceValues(formData: FormData) {
  const truckId = String(formData.get("truck_id") || "").trim();
  const driverId = String(formData.get("driver_id") || "").trim();
  if (!truckId) throw new Error("Truck is required.");
  if (!driverId) throw new Error("Driver is required.");
  return {
    truck_id: truckId,
    driver_id: driverId,
    trailer_id: emptyToNull(formData.get("trailer_id")),
  };
}

// Phase 3A.4 (item 2): status is NOT part of this action at all, in either
// direction. Preferred design selected over a combined orchestration RPC:
// status transitions stay EXCLUSIVELY on the Dispatch Board
// (updateDispatchBoardStatus, board-actions.ts) or a future dedicated
// status action -- both already route through transition_dispatch_status()
// (0134) on their own, unaffected by this file. Removing status from this
// form structurally eliminates the partial-success risk a combined "Save"
// ever had (status applied via one RPC, resources rejected by a second,
// independent one, in two separate transactions, presented to the user as
// one action): there is now only ONE mutating RPC call anywhere in this
// function's body (reassign_dispatch_resources, and only when a resource
// actually changed -- see resourcesChanged below), plus the separately-
// safe (per-row-upsert, no shared transaction to partially fail)
// financials/notes table writes. A rejected resource reassignment can
// never leave a status change applied out from under it, because this
// action never touches status at all.
//
// Plain update -- same row, same id, no duplicate ever created. Same
// useActionState/expected-error convention as createDispatch.
export async function updateDispatch(id: string, _prevState: DispatchActionState, formData: FormData): Promise<DispatchActionState> {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();

  try {
    const values = updateDispatchResourceValues(formData);

    // Phase 3A.4 (item 3): fetch the CURRENTLY SAVED assignment ONCE --
    // authoritative for BOTH the carrier-tamper check below AND the "did
    // driver/truck/trailer actually change" decision that follows. Never
    // trust the browser to decide whether a resource-reassignment RPC call
    // is even needed, any more than the RPC itself trusts the browser to
    // decide whether a change is a REPLACEMENT (0135, Phase 3A.4 item 1).
    const { data: currentDispatch, error: currentDispatchError } = await supabase
      .from("dispatches")
      .select("carrier_id, driver_id, truck_id, trailer_id")
      .eq("id", id)
      .maybeSingle();
    if (currentDispatchError || !currentDispatch) {
      throw new DispatchConflictError("This dispatch could not be found. It may have been removed.", { code: "DISPATCH_NOT_FOUND", field: null });
    }

    // Phase 3A.2 (item 1): a dispatch's carrier must not be changed through
    // this ordinary form. The rendered field is now read-only
    // (dispatch/[id]/page.tsx), so a normal submission never carries a
    // carrier_id at all -- but a tampered or stale request (a hand-crafted
    // POST, or a stale form that captured an old carrier_id before someone
    // else changed it) is NOT silently ignored: if one arrives and
    // disagrees with the dispatch's actual current carrier, the whole
    // update is rejected outright, not partially applied.
    const submittedCarrierId = emptyToNull(formData.get("carrier_id"));
    if (submittedCarrierId !== null && currentDispatch.carrier_id !== submittedCarrierId) {
      throw new DispatchConflictError(
        "Carrier is controlled by the load and cannot be changed here. Your request appears to be stale or tampered with -- reload this page and try again, or use the controlled carrier-reassignment workflow to change it.",
        { code: "CARRIER_CHANGE_REJECTED", field: null }
      );
    }

    // Phase 3A.4 (item 3): call reassign_dispatch_resources() ONLY when
    // driver/truck/trailer actually differ from what is CURRENTLY saved --
    // never for a notes-only edit, and never merely because a currently-
    // assigned resource has since gone inactive or unresolved (that
    // resource isn't being REPLACED by this save, so its own status/scope
    // is irrelevant to it). This is a pure efficiency/UX decision, not a
    // security boundary: the RPC re-derives "is this a replacement" itself,
    // under its own lock, from the database row (0135), exactly as
    // strictly as if this check did not exist -- it just means an
    // unrelated save is never rejected on account of a historical resource
    // it isn't touching.
    const resourcesChanged =
      values.driver_id !== currentDispatch.driver_id ||
      values.truck_id !== currentDispatch.truck_id ||
      (values.trailer_id ?? null) !== (currentDispatch.trailer_id ?? null);

    // Read once, reused below for the idempotency key (when a resource
    // actually changes) AND for the financials/notes writes that always
    // run -- avoids a redundant current_org_id() round trip either way.
    const organizationId = await getCurrentOrgId();

    if (resourcesChanged) {
      await checkEquipmentAvailable(supabase, { truckId: values.truck_id, trailerId: values.trailer_id });
      await checkAssignmentConflicts(supabase, {
        driverId: values.driver_id,
        truckId: values.truck_id,
        trailerId: values.trailer_id,
        excludeDispatchId: id,
      });

      const reassignmentReason = emptyToNull(formData.get("reassignment_reason"));
      const expectedUpdatedAt = emptyToNull(formData.get("expected_updated_at"));
      // Phase 3A.4 (item 4): server-generated, deterministic idempotency
      // key -- see reassignment-idempotency.ts for the full contract. A
      // byte-identical retry of this same submission (same dispatch,
      // driver/truck/trailer, reason, and version) always reduces to the
      // SAME key with nothing stored client- or server-side; any actual
      // change to what is being submitted produces a different one.
      const idempotencyKey = buildReassignmentIdempotencyKey({
        organizationId,
        dispatchId: id,
        driverId: values.driver_id,
        truckId: values.truck_id,
        trailerId: values.trailer_id,
        reason: reassignmentReason,
        expectedUpdatedAt,
      });

      const { data: resourceResult, error: resourceError } = await supabase.rpc("reassign_dispatch_resources", {
        p_dispatch_id: id,
        p_driver_id: values.driver_id,
        p_truck_id: values.truck_id,
        p_trailer_id: values.trailer_id,
        p_reason: reassignmentReason,
        p_idempotency_key: idempotencyKey,
        p_expected_updated_at: expectedUpdatedAt,
      });
      if (resourceError) {
        // reassign_dispatch_resources() (0135) translates a 0054 unique-
        // violation race into its OWN friendly RRDRV/RRTRK/RRTRL error
        // internally -- a raw 23505 never escapes this RPC, unlike the old
        // direct-UPDATE path this replaced (matchedUniqueIndex/
        // raceLoserConflict are for THAT raw-constraint shape and no
        // longer apply here).
        const conflict = rpcDispatchConflict(resourceError);
        throw conflict ? new DispatchConflictError(conflict.message, { code: conflict.code, field: conflict.field }) : resourceError;
      }
      // Phase 3A.3/3A.4 (item 3 / item 1): a stale or missing expected_
      // updated_at comes back as a STRUCTURED result, not a thrown error --
      // the RPC made no change and wrote no audit event either way.
      // Translate both into the same DispatchConflictError shape as every
      // other expected conflict so the user sees one consistent alert.
      const resourceOutcome = resourceResult as
        | { success?: boolean; stale_record?: boolean; expected_version_required?: boolean; message?: string }
        | null;
      if (resourceOutcome?.stale_record) {
        throw new DispatchConflictError(
          resourceOutcome.message ??
            "This dispatch was changed by someone else while you were editing it. Please refresh and review the latest assignment before trying again.",
          { code: "STALE_RECORD", field: null }
        );
      }
      if (resourceOutcome?.expected_version_required) {
        throw new DispatchConflictError(
          resourceOutcome.message ?? "This reassignment requires the version of the dispatch you loaded. Please reload the page and try again.",
          { code: "EXPECTED_VERSION_REQUIRED", field: null }
        );
      }
    }

    // Phase 2G.10: same split as createDispatch above.
    await writeDispatchFinancials(supabase, id, organizationId, formData);
    await writeDispatchNotes(supabase, id, organizationId, formData);

    // Phase 2I.1: logs the general "updated" action unconditionally,
    // matching this action's prior semantics for anyone watching the
    // Activity section for non-resource edits (notes/fee only), without
    // duplicating the resource-specific detail reassign_dispatch_
    // resources() already recorded when resourcesChanged was true.
    await supabase.rpc("log_activity", {
      p_entity_type: "dispatch",
      p_entity_id: id,
      p_action: "updated",
      p_changes: null,
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
