"use client";

import { useEffect, useRef } from "react";
import { getUnreadDriverMessageAlert } from "@/app/(app)/dispatch/message-alert-actions";
import { decideMessageAlert } from "@/lib/notify/message-alert";
import { installChimeUnlock, playMessageChime } from "@/lib/notify/message-chime";
import { useToast } from "@/components/ui/toast";

const POLL_MS = 15000;

// Staff side of the "new message" chime. Mounted once in the (app) layout
// (only for owner/admin/dispatcher), so it works on every page -- not just
// the Dispatch Board. Plays the chime and shows a toast naming the driver
// and load when a driver sends a new message. The first check after a page
// load only records what's already unread (no chime for old messages).
export function MessageAlertWatcher() {
  const toast = useToast();
  const baseline = useRef<string | null | undefined>(undefined);

  useEffect(() => installChimeUnlock(), []);

  useEffect(() => {
    let cancelled = false;
    let inFlight = false;
    const check = () => {
      if (inFlight || cancelled) return;
      inFlight = true;
      getUnreadDriverMessageAlert()
        .then((alert) => {
          if (cancelled) return;
          const decision = decideMessageAlert(baseline.current, alert);
          baseline.current = decision.baseline;
          if (decision.chime && alert.latest) {
            playMessageChime();
            const who = alert.latest.driverName ?? "Driver";
            const load = alert.latest.loadNumber ? ` (${alert.latest.loadNumber})` : "";
            toast.show("info", `New message from ${who}${load}: ${alert.latest.preview}`);
          }
        })
        .catch(() => {})
        .finally(() => {
          inFlight = false;
        });
    };
    check();
    const interval = setInterval(check, POLL_MS);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return null;
}
