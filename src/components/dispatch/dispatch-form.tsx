"use client";

import { useActionState } from "react";
import { DispatchFormStateContext } from "./dispatch-form-state";
import { DISPATCH_ACTION_INITIAL_STATE, type DispatchActionState } from "@/lib/dispatch/errors";

// Client wrapper around the actual <form> -- the one piece of this page
// that has to be a Client Component, since useActionState is what turns a
// thrown DispatchConflictError into normal render state instead of an
// uncaught exception reaching the route's error boundary. Everything else
// (Load Summary, Trip/Stops, the Assignment fields, financials, etc.) stays
// exactly the Server-Component-built JSX it already was -- passed in as
// children, not rebuilt here.
//
// Submitting on a conflict re-renders THIS SAME mounted form with new
// `state` -- no navigation, no remount -- which is what naturally preserves
// every uncontrolled input's current value (spec section 7/9/10) without
// any manual "echo the form data back" plumbing.
export function DispatchForm({
  id,
  action,
  className,
  children,
}: {
  id?: string;
  action: (prevState: DispatchActionState, formData: FormData) => Promise<DispatchActionState>;
  className?: string;
  children: React.ReactNode;
}) {
  // Wraps the real server action so a failed submit's state always carries
  // back exactly what the user typed/selected -- see DispatchActionState.
  // On success the action redirect()s and this return value is never used.
  async function actionWithEcho(prevState: DispatchActionState, formData: FormData): Promise<DispatchActionState> {
    const result = await action(prevState, formData);
    return {
      ...result,
      values: {
        carrierId: String(formData.get("carrier_id") || ""),
        driverId: String(formData.get("driver_id") || ""),
        truckId: String(formData.get("truck_id") || ""),
        trailerId: String(formData.get("trailer_id") || ""),
        feePercentage: String(formData.get("dispatch_fee_percentage") || ""),
        notes: String(formData.get("notes") || ""),
      },
    };
  }

  const [state, formAction] = useActionState(actionWithEcho, DISPATCH_ACTION_INITIAL_STATE);

  return (
    <form id={id} action={formAction} className={className}>
      <DispatchFormStateContext.Provider value={state}>{children}</DispatchFormStateContext.Provider>
    </form>
  );
}
