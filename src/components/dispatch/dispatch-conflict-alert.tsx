"use client";

import Link from "next/link";
import { AlertTriangle } from "lucide-react";
import { useDispatchFormState } from "./dispatch-form-state";

const FIELD_ELEMENT_ID: Record<string, string> = { driver: "driver_id", truck: "truck_id", trailer: "trailer_id" };
const FIELD_LABEL: Record<string, string> = { driver: "Driver", truck: "Truck", trailer: "Trailer" };

const HEADING_BY_CODE: Record<string, string> = {
  DRIVER_ACTIVE_DISPATCH: "Driver unavailable",
  TRUCK_ACTIVE_DISPATCH: "Truck unavailable",
  TRAILER_ACTIVE_DISPATCH: "Trailer unavailable",
  TRUCK_OUT_OF_SERVICE: "Truck unavailable",
  TRAILER_OUT_OF_SERVICE: "Trailer unavailable",
  CARRIER_MISMATCH: "Assignment not valid",
  LOAD_ALREADY_DISPATCHED: "Load already dispatched",
  CONCURRENT_UPDATE: "Assignment just changed",
  VALIDATION_ERROR: "Missing information",
  UNKNOWN: "Couldn't save this dispatch",
};

// Renders the one professional, in-form conflict panel every expected
// dispatch business error uses (spec sections 3-7): compact alert, plain-
// language explanation, relevant action buttons, no stack trace/digest/
// SQL text -- ever. Reads its content entirely from the single canonical
// DispatchActionState the server action returned (spec section 8: "one
// canonical error result rather than duplicating conflict logic client-
// side") -- this component has no conflict-detection logic of its own.
export function DispatchConflictAlert() {
  const state = useDispatchFormState();
  if (!state.error) return null;

  const heading = (state.code && HEADING_BY_CODE[state.code]) || "Couldn't save this dispatch";
  const isOutOfService = state.code === "TRUCK_OUT_OF_SERVICE" || state.code === "TRAILER_OUT_OF_SERVICE";
  const isActiveDispatchConflict = state.code === "DRIVER_ACTIVE_DISPATCH" || state.code === "TRUCK_ACTIVE_DISPATCH" || state.code === "TRAILER_ACTIVE_DISPATCH";
  const isLoadAlreadyDispatched = state.code === "LOAD_ALREADY_DISPATCHED";
  const fieldLabel = state.field ? FIELD_LABEL[state.field] : null;

  function focusField() {
    if (!state.field) return;
    const el = document.getElementById(FIELD_ELEMENT_ID[state.field]);
    el?.focus();
    el?.scrollIntoView({ behavior: "smooth", block: "center" });
  }

  return (
    <div role="alert" className="flex items-start gap-2.5 rounded-md border border-danger/30 bg-danger/5 px-3.5 py-3 text-[13px]">
      <AlertTriangle className="mt-0.5 size-4 shrink-0 text-danger" />
      <div className="flex-1 space-y-2">
        <div>
          <p className="font-semibold text-danger">{heading}</p>
          <p className="mt-0.5 text-desktop-text">{state.error}</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {(isActiveDispatchConflict || isLoadAlreadyDispatched) && state.conflictDispatchId && (
            <Link
              href={`/dispatch/${state.conflictDispatchId}`}
              className="inline-flex h-7 items-center rounded-sm border border-desktop-border bg-desktop-panel px-2.5 text-[12px] font-medium text-desktop-text transition-colors hover:bg-desktop-muted"
            >
              View Active Dispatch
            </Link>
          )}
          {isOutOfService &&
            (state.maintenanceId ? (
              <Link
                href={`/maintenance/${state.maintenanceId}`}
                className="inline-flex h-7 items-center rounded-sm border border-desktop-border bg-desktop-panel px-2.5 text-[12px] font-medium text-desktop-text transition-colors hover:bg-desktop-muted"
              >
                View Maintenance
              </Link>
            ) : (
              <Link
                href="/maintenance"
                className="inline-flex h-7 items-center rounded-sm border border-desktop-border bg-desktop-panel px-2.5 text-[12px] font-medium text-desktop-text transition-colors hover:bg-desktop-muted"
              >
                View Maintenance
              </Link>
            ))}
          {fieldLabel && (isActiveDispatchConflict || isOutOfService) && (
            <button
              type="button"
              onClick={focusField}
              className="inline-flex h-7 items-center rounded-sm px-2.5 text-[12px] font-medium text-primary transition-colors hover:bg-desktop-muted"
            >
              Choose Another {fieldLabel}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
