"use client";

import { useEffect, useRef, useState } from "react";
import { RadioTower, AlertTriangle, Info } from "lucide-react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { startTrackingSession, stopTrackingSession } from "@/app/driver-portal/tracking-actions";
import { distanceMeters } from "@/lib/geo/distance";

const MIN_SEND_INTERVAL_MOVING_MS = 25_000; // ~20-30s while moving
const MIN_SEND_INTERVAL_STATIONARY_MS = 90_000; // ~60-120s while stationary
const MOVING_SPEED_THRESHOLD_MPS = 1; // ~2.2 mph -- below this, treat as stationary for throttling purposes
const MEANINGFUL_DISTANCE_METERS = 150; // send anyway if moved this far, even before the timer

type ShareState = "off" | "confirming" | "sharing" | "permission_required" | "unable";

const STATE_LABEL: Record<ShareState, string> = {
  off: "Stopped",
  confirming: "Confirming",
  sharing: "Sharing",
  permission_required: "Permission Required",
  unable: "Unable to Get Location",
};

function secondsAgoLabel(date: Date | null, nowTick: number): string {
  if (!date) return "--";
  const secs = Math.max(0, Math.round((nowTick - date.getTime()) / 1000));
  if (secs < 60) return `${secs} sec ago`;
  const mins = Math.round(secs / 60);
  return `${mins} min ago`;
}

// Real foreground GPS sharing tied to a formal driver_tracking_sessions
// row (Start Trip / Stop Trip -- 0058_driver_phone_gps.sql), on top of the
// existing /api/driver-portal/location ping route and driver_locations
// table, unchanged. Foreground only -- this app makes no claim of reliable
// background tracking (spec section 16); the copy below says so plainly.
export function LocationSharing({
  currentLoadNumber,
  route,
  initiallyActive = false,
}: {
  currentLoadNumber: string | null;
  route?: string | null;
  /** True when driver_tracking_sessions already has an active row for this
   * driver (resolved server-side by the page). A fresh page load always
   * loses the browser's watchPosition regardless of DB state -- without
   * this, refreshing mid-trip would wrongly show "off" even though the
   * driver never stopped sharing. */
  initiallyActive?: boolean;
}) {
  const [state, setState] = useState<ShareState>("off");
  const [lastSentAt, setLastSentAt] = useState<Date | null>(null);
  const [lastAccuracy, setLastAccuracy] = useState<number | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const watchIdRef = useRef<number | null>(null);
  const lastSentRef = useRef<number>(0);
  const lastSentPosRef = useRef<{ lat: number; lon: number } | null>(null);

  useEffect(() => {
    return () => {
      if (watchIdRef.current !== null) navigator.geolocation.clearWatch(watchIdRef.current);
    };
  }, []);

  // Resume automatically if a session was already active before this page
  // load (see the initiallyActive comment above) -- calls the exact same
  // start path a manual "Start Trip" tap would, which is safe to call
  // again: startTrackingSession() resumes an existing active row rather
  // than creating a duplicate. No consent re-prompt; the driver already
  // gave it when they first tapped Start Trip this trip.
  useEffect(() => {
    if (initiallyActive) confirmAndStart();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Live "X sec ago" ticker -- only runs while actively sharing, so it
  // never spins a background timer for no reason once stopped.
  useEffect(() => {
    if (state !== "sharing") return;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [state]);

  function stopWatch() {
    if (watchIdRef.current !== null) {
      navigator.geolocation.clearWatch(watchIdRef.current);
      watchIdRef.current = null;
    }
  }

  async function stop() {
    stopWatch();
    setState("off");
    await stopTrackingSession();
  }

  async function confirmAndStart() {
    if (!("geolocation" in navigator)) {
      setState("unable");
      setErrorMsg("This device's browser doesn't support location sharing.");
      return;
    }
    setErrorMsg(null);
    setState("confirming");

    const session = await startTrackingSession();
    if (!session.ok) {
      setState("unable");
      setErrorMsg(session.error);
      return;
    }

    // Permission is requested by the browser the moment watchPosition is
    // called -- tracking only actually begins once (if) the driver grants
    // it, handled by the success/error callbacks below.
    watchIdRef.current = navigator.geolocation.watchPosition(
      async (position) => {
        setState("sharing");
        const { latitude, longitude, accuracy, heading, speed, altitude } = position.coords;
        setLastAccuracy(accuracy ?? null);

        const nowMs = Date.now();
        const moving = speed !== null && speed >= MOVING_SPEED_THRESHOLD_MPS;
        const minInterval = moving ? MIN_SEND_INTERVAL_MOVING_MS : MIN_SEND_INTERVAL_STATIONARY_MS;
        const elapsed = nowMs - lastSentRef.current;

        const movedFar = lastSentPosRef.current
          ? distanceMeters(lastSentPosRef.current.lat, lastSentPosRef.current.lon, latitude, longitude) >= MEANINGFUL_DISTANCE_METERS
          : true; // always send the first fix

        if (elapsed < minInterval && !movedFar) return;
        lastSentRef.current = nowMs;
        lastSentPosRef.current = { lat: latitude, lon: longitude };

        try {
          const res = await fetch("/api/driver-portal/location", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              latitude,
              longitude,
              accuracy,
              heading,
              speedKph: speed !== null ? speed * 3.6 : null,
              altitude,
            }),
          });
          if (res.ok) setLastSentAt(new Date());
        } catch {
          // Keep showing "Sharing" -- the browser is still capturing
          // positions; only a genuine permission/geolocation failure
          // changes state (the error callback below), never a transient
          // network hiccup on one ping.
        }
      },
      (err) => {
        const denied = err.code === err.PERMISSION_DENIED;
        setState(denied ? "permission_required" : "unable");
        setErrorMsg(err.message || (denied ? "Location permission was denied." : "Couldn't get your location."));
        stopWatch();
      },
      { enableHighAccuracy: true, maximumAge: 10_000, timeout: 20_000 }
    );
  }

  const lowAccuracy = lastAccuracy !== null && lastAccuracy > 200;

  if (state === "off" || state === "confirming") {
    return (
      <div className="rounded-2xl border border-border bg-card p-4">
        <p className="text-sm font-semibold">Location Sharing</p>
        <p className="mt-1 text-sm text-muted-foreground">Location sharing is off.</p>
        <p className="mt-2 text-xs text-muted-foreground">
          Starting a trip shares your location with your dispatch company while it&apos;s active. Your browser will ask for
          location permission.
        </p>
        <Button type="button" className="mt-3 w-full" onClick={confirmAndStart} disabled={state === "confirming"}>
          {state === "confirming" ? "Starting..." : "Start Trip"}
        </Button>
        {errorMsg && (
          <p className="mt-2 flex items-start gap-1.5 text-xs text-danger">
            <AlertTriangle className="mt-0.5 size-3.5 shrink-0" /> {errorMsg}
          </p>
        )}
      </div>
    );
  }

  if (state === "permission_required" || state === "unable") {
    return (
      <div className="rounded-2xl border border-border bg-card p-4">
        <p className="text-sm font-semibold">Location Sharing</p>
        <p className="mt-1 flex items-start gap-1.5 text-sm text-danger">
          <AlertTriangle className="mt-0.5 size-3.5 shrink-0" /> {STATE_LABEL[state]}
        </p>
        {errorMsg && <p className="mt-1 text-xs text-muted-foreground">{errorMsg}</p>}
        <Button type="button" className="mt-3 w-full" onClick={confirmAndStart}>
          Try Again
        </Button>
      </div>
    );
  }

  return (
    <div className="rounded-2xl border border-success/30 bg-card p-4">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-2.5">
          <div className="flex size-9 items-center justify-center rounded-lg bg-success/10 text-success">
            <RadioTower className="size-4" />
          </div>
          <div>
            <p className="text-sm font-semibold uppercase tracking-wide text-success">Live Tracking</p>
            <p className="text-xs text-muted-foreground">
              Location Sharing: <span className="font-medium text-success">ON</span>
            </p>
          </div>
        </div>
        <Button type="button" variant="secondary" size="sm" onClick={stop}>
          Stop Trip
        </Button>
      </div>

      {route && <p className="mt-3 text-sm font-medium">{route}</p>}

      <div className="mt-3 grid grid-cols-2 gap-2 border-t border-border pt-3 text-xs">
        <div>
          <p className="font-medium uppercase tracking-wide text-muted-foreground">Last Update</p>
          <p className="mt-0.5 font-medium">{secondsAgoLabel(lastSentAt, now)}</p>
        </div>
        <div>
          <p className="font-medium uppercase tracking-wide text-muted-foreground">GPS Accuracy</p>
          <p className={cn("mt-0.5 font-medium", lowAccuracy && "text-warning")}>
            {lastAccuracy !== null ? `${Math.round(lastAccuracy)} m` : "--"}
            {lowAccuracy && " (low)"}
          </p>
        </div>
        <div className="col-span-2">
          <p className="font-medium uppercase tracking-wide text-muted-foreground">Current Trip</p>
          <p className="mt-0.5 font-medium">{currentLoadNumber ?? "None"}</p>
        </div>
      </div>

      <p className="mt-3 flex items-start gap-1.5 border-t border-border pt-2.5 text-[11px] text-muted-foreground">
        <Info className="mt-0.5 size-3.5 shrink-0" />
        Keep this page open for reliable tracking. Tracking may pause if your phone locks or the browser is closed.
      </p>
    </div>
  );
}
