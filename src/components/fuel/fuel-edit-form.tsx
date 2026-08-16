"use client";

import { useActionState } from "react";
import { updateFuelLog } from "@/app/(app)/fuel/actions";
import { FUEL_ACTION_INITIAL_STATE } from "@/lib/fuel/errors";

// Owns the actual <form id="fuel-edit-form"> DOM element -- Payment &
// Responsibility (a separate collapsible section, rendered by the Server
// Component page) and the Save Changes button below it both associate to
// this same id via the HTML form="..." attribute, which resolves by DOM
// id regardless of the React/Server-Client component boundary, so moving
// this one <form> into a Client Component doesn't break that association.
//
// useActionState (spec "ERROR UX"): a rejected save (locked record,
// recoverable amount over the total, missing responsible driver) comes
// back as normal state, shown as one inline banner here, never the
// full-screen Next.js Runtime Error overlay.
export function FuelEditForm({ id, children }: { id: string; children: React.ReactNode }) {
  const [state, formAction] = useActionState(updateFuelLog.bind(null, id), FUEL_ACTION_INITIAL_STATE);

  return (
    <form id="fuel-edit-form" action={formAction}>
      {state.error && (
        <p className="mb-3 rounded-md border border-danger/30 bg-danger/5 px-3 py-2 text-[12.5px] text-danger">{state.error}</p>
      )}
      {children}
    </form>
  );
}
