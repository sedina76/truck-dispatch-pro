"use client";

import { useEffect, useRef } from "react";
import { useRouter } from "next/navigation";
import { getUnreadDriverMessageAlert, getUnreadNotificationAlert } from "@/app/(app)/dispatch/message-alert-actions";
import { decideMessageAlert } from "@/lib/notify/message-alert";
import { installChimeUnlock, playMessageChime } from "@/lib/notify/message-chime";
import { useToast } from "@/components/ui/toast";

const POLL_MS = 15000;

// Staff side of the chime. Mounted once in the (app) layout for every staff
// role, so it works on every page. Checks every 15 seconds for:
//   * a new driver message (owner/admin/dispatcher; the server returns
//     nothing for other roles), and
//   * a new notification in the bell (POD uploaded, exceptions, late /
//     off-route trucks, ...) -- which also refreshes the bell.
// Each plays the chime once with a toast. The first check after a page load
// only records what's already unread (no chime for old items).
export function MessageAlertWatcher() {
  const toast = useToast();
  const router = useRouter();
  const messageBaseline = useRef<string | null | undefined>(undefined);
  const notificationBaseline = useRef<string | null | undefined>(undefined);

  useEffect(() => installChimeUnlock(), []);

  useEffect(() => {
    let cancelled = false;
    let inFlight = false;
    const check = () => {
      if (inFlight || cancelled) return;
      inFlight = true;
      Promise.all([getUnreadDriverMessageAlert(), getUnreadNotificationAlert()])
        .then(([message, notification]) => {
          if (cancelled) return;
          const m = decideMessageAlert(messageBaseline.current, message);
          messageBaseline.current = m.baseline;
          const n = decideMessageAlert(notificationBaseline.current, notification);
          notificationBaseline.current = n.baseline;
          if (m.chime || n.chime) playMessageChime();
          if (m.chime && message.latest) {
            const who = message.latest.driverName ?? "Driver";
            const load = message.latest.loadNumber ? ` (${message.latest.loadNumber})` : "";
            toast.show("info", `New message from ${who}${load}: ${message.latest.preview}`);
          }
          if (n.chime && notification.latest) {
            toast.show("info", notification.latest.body ? `${notification.latest.title}: ${notification.latest.body}` : notification.latest.title);
            router.refresh(); // the bell shows it right away
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
