"use client";

import { useEffect, useState } from "react";
import { MonitorUp } from "lucide-react";
import { desktopAlertState, requestDesktopAlerts, showDesktopAlert, type DesktopAlertState } from "@/lib/notify/desktop-alert";
import { cn } from "@/lib/utils";

// Status-bar switch for system notifications (alerts while the TMS is in the
// background). Asking for permission must come from this click.
export function DesktopAlertToggle({ className }: { className?: string }) {
  const [state, setState] = useState<DesktopAlertState>("unsupported");
  useEffect(() => setState(desktopAlertState()), []);
  if (state === "unsupported") return null;

  async function enable() {
    const next = await requestDesktopAlerts();
    setState(next);
    if (next === "granted") showDesktopAlert("Background alerts are on", "You'll get a notification for new driver messages and TMS notifications, even in another tab or app.", { tag: "tdp-alerts-on" });
  }

  if (state === "granted") {
    return (
      <span className={cn("inline-flex items-center gap-1", className)} title="System notifications are on for this browser">
        <MonitorUp className="size-3" /> Background alerts on
      </span>
    );
  }
  if (state === "denied") {
    return (
      <span className={cn("inline-flex items-center gap-1 text-warning", className)} title="Blocked in the browser. Safari: Settings > Websites > Notifications > allow this site. Chrome: click the lock icon in the address bar > Notifications > Allow.">
        <MonitorUp className="size-3" /> Background alerts blocked
      </span>
    );
  }
  return (
    <button type="button" onClick={enable} className={cn("inline-flex items-center gap-1 font-medium text-primary hover:underline", className)} title="Get a notification with sound even when the TMS is in another tab or app">
      <MonitorUp className="size-3" /> Turn on background alerts
    </button>
  );
}
