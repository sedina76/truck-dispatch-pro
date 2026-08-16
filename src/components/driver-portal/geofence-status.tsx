"use client";

import { useState, useTransition } from "react";
import { MapPinned, CheckCircle2, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { confirmGeofenceArrival } from "@/app/driver-portal/tracking-actions";

export type GeofenceStopInfo = {
  loadStopId: string;
  companyName: string | null;
  city: string | null;
  state: string | null;
  hasCoordinates: boolean;
  geofenceState: "outside" | "candidate_inside" | "inside" | "candidate_outside" | "exited" | null;
  distanceM: number | null;
  radiusM: number;
  statusApplied: boolean;
};

// Spec section 22's exact status vocabulary, derived from the dispatch's
// own status plus each stop's confirmed geofence state -- never a second,
// competing status of its own. "Approaching"/"En Route" fall back on
// distance alone (a wider, informal band) since those two aren't part of
// the confirmed state machine.
function currentLabel(
  dispatchStatus: string,
  pickup: GeofenceStopInfo | null,
  delivery: GeofenceStopInfo | null
): string | null {
  switch (dispatchStatus) {
    case "en_route_to_pickup": {
      const s = pickup?.geofenceState;
      if (s === "inside") return "Pickup Arrival Detected";
      if (s === "candidate_inside") return "Inside Pickup Geofence";
      return "Approaching Pickup";
    }
    case "at_pickup":
      return "At Pickup";
    case "loaded":
      return "Loaded";
    case "en_route_to_delivery": {
      const s = delivery?.geofenceState;
      if (s === "inside") return "Delivery Arrival Detected";
      if (s === "candidate_inside") return "Inside Delivery Geofence";
      if (delivery?.distanceM != null && delivery.distanceM <= delivery.radiusM * 3) return "Approaching Delivery";
      return "En Route";
    }
    case "at_delivery":
      return "At Delivery";
    default:
      return null;
  }
}

// The one-tap confirmation prompt (spec section 14) -- only shown when GPS
// has already, server-side, multi-ping-confirmed presence at a stop
// (geofenceState === 'inside') and that confirmation hasn't been applied to
// the dispatch's status yet (statusApplied === false, i.e. the org is in
// 'suggest' automation mode). "Not Yet" is a local dismiss only -- GPS
// keeps confirming in the background regardless, there is nothing to undo
// server-side by tapping it.
function ConfirmArrivalPrompt({ stop, kind }: { stop: GeofenceStopInfo; kind: "pickup" | "delivery" }) {
  const [dismissed, setDismissed] = useState(false);
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [confirmed, setConfirmed] = useState(false);

  if (dismissed || confirmed) return null;

  function confirm() {
    setError(null);
    startTransition(async () => {
      const result = await confirmGeofenceArrival(stop.loadStopId);
      if (result.ok) setConfirmed(true);
      else setError(result.error);
    });
  }

  return (
    <div className="rounded-2xl border border-primary/30 bg-primary/5 p-4">
      <p className="flex items-center gap-1.5 text-sm font-semibold text-primary">
        <MapPinned className="size-4" /> {kind === "pickup" ? "Pickup" : "Delivery"} detected
      </p>
      <p className="mt-1 text-sm text-muted-foreground">
        It looks like you&apos;ve arrived at{stop.companyName ? ` ${stop.companyName}` : ""}
        {stop.city ? ` (${stop.city}${stop.state ? `, ${stop.state}` : ""})` : ""}.
      </p>
      <div className="mt-3 flex gap-2">
        <Button type="button" className="flex-1" onClick={confirm} disabled={pending}>
          {pending ? <Loader2 className="size-4 animate-spin" /> : "Confirm Arrival"}
        </Button>
        <Button type="button" variant="secondary" className="flex-1" onClick={() => setDismissed(true)} disabled={pending}>
          Not Yet
        </Button>
      </div>
      {error && <p className="mt-2 text-xs text-danger">{error}</p>}
    </div>
  );
}

export function GeofenceStatusCard({
  dispatchStatus,
  pickup,
  delivery,
  automationMode,
}: {
  dispatchStatus: string;
  pickup: GeofenceStopInfo | null;
  delivery: GeofenceStopInfo | null;
  automationMode: "off" | "suggest" | "automatic";
}) {
  if (automationMode === "off") return null;

  const label = currentLabel(dispatchStatus, pickup, delivery);
  const activeStop = dispatchStatus === "en_route_to_pickup" ? pickup : dispatchStatus === "en_route_to_delivery" ? delivery : null;
  const missingCoords = activeStop && !activeStop.hasCoordinates;

  // Awaiting a driver tap only ever applies in 'suggest' mode -- in
  // 'automatic' mode the transition already happened server-side by the
  // time this page next renders, so statusApplied is already true.
  const pendingConfirm =
    automationMode === "suggest" && activeStop?.geofenceState === "inside" && !activeStop.statusApplied
      ? { stop: activeStop, kind: (dispatchStatus === "en_route_to_pickup" ? "pickup" : "delivery") as "pickup" | "delivery" }
      : null;

  if (pendingConfirm) return <ConfirmArrivalPrompt stop={pendingConfirm.stop} kind={pendingConfirm.kind} />;

  if (!label) return null;

  return (
    <div className="rounded-2xl border border-border bg-card p-3">
      <p className="flex items-center gap-1.5 text-sm font-medium">
        {label === "At Pickup" || label === "At Delivery" ? (
          <CheckCircle2 className="size-4 text-success" />
        ) : (
          <MapPinned className="size-4 text-muted-foreground" />
        )}
        {label}
      </p>
      {missingCoords && <p className="mt-1 text-xs text-muted-foreground">Geofence unavailable -- stop coordinates missing.</p>}
    </div>
  );
}
