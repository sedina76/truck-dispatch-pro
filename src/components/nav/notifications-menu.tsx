"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { Bell, BellRing, CheckCheck } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuTrigger,
  DropdownMenuSeparator,
} from "@/components/ui/dropdown-menu";
import { markAllNotificationsRead, markNotificationRead, getMyNotifications } from "@/lib/actions/notifications";

type NotificationRow = {
  id: string;
  title: string;
  body: string | null;
  type: string;
  // Phase 2I.1A section E -- entity_type/entity_id already existed on
  // `notifications` (0007); only needed in this row shape once a
  // notification type (dispatch_message) actually has somewhere to
  // navigate to. Every other existing type keeps its current mark-read-
  // only behavior untouched.
  entity_type: string | null;
  entity_id: string | null;
  // Phase 2P.6B -- set only for exception-sourced notifications (0107).
  exception_id: string | null;
  read_at: string | null;
  created_at: string;
};

export function NotificationsMenu({ notifications: initialNotifications }: { notifications: NotificationRow[] }) {
  // Seeded from the server-rendered layout for first paint; kept fresh
  // afterward by the 20s poll below. Also re-synced whenever the server
  // prop itself changes (e.g. markAllNotificationsRead's revalidatePath
  // causing (app)/layout.tsx to re-run on the next server render) --
  // same "merge/re-sync on prop change" precedent as
  // communication-panel.tsx's initialMessages effect.
  const [notifications, setNotifications] = useState(initialNotifications);
  useEffect(() => {
    setNotifications(initialNotifications);
  }, [initialNotifications]);

  // Phase 2I.1A section K -- lightweight 20s polling via the existing
  // narrow getMyNotifications() server action (same query the layout
  // already runs), never a websocket/Realtime channel. Guarded against
  // overlap; stops on unmount.
  useEffect(() => {
    let cancelled = false;
    let inFlight = false;
    const interval = setInterval(() => {
      if (inFlight || cancelled) return;
      inFlight = true;
      getMyNotifications()
        .then((fresh) => {
          if (!cancelled) setNotifications(fresh);
        })
        .catch(() => {})
        .finally(() => {
          inFlight = false;
        });
    }, 20000);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, []);

  const unreadCount = notifications.filter((n) => !n.read_at).length;

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button type="button" variant="ghost" size="icon" className="relative" aria-label="Notifications">
          {unreadCount > 0 ? <BellRing className="size-4" /> : <Bell className="size-4" />}
          {unreadCount > 0 && (
            <span className="absolute right-1.5 top-1.5 flex size-3.5 items-center justify-center rounded-full bg-danger text-[9px] font-semibold text-danger-foreground">
              {unreadCount > 9 ? "9+" : unreadCount}
            </span>
          )}
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-80 p-0">
        <div className="flex items-center justify-between border-b border-border px-3 py-2.5">
          <p className="text-sm font-semibold">Notifications</p>
          {unreadCount > 0 && (
            <form action={markAllNotificationsRead}>
              <button type="submit" className="flex items-center gap-1 text-xs font-medium text-primary hover:underline">
                <CheckCheck className="size-3.5" />
                Mark all read
              </button>
            </form>
          )}
        </div>
        <div className="max-h-96 overflow-y-auto p-1.5">
          {notifications.length === 0 ? (
            <div className="flex flex-col items-center gap-2 px-4 py-10 text-center">
              <div className="flex size-10 items-center justify-center rounded-full bg-muted text-muted-foreground">
                <Bell className="size-5" />
              </div>
              <p className="text-sm font-medium">You&apos;re all caught up</p>
              <p className="text-xs text-muted-foreground">New alerts about loads, compliance, and payments will show up here.</p>
            </div>
          ) : (
            notifications.map((n) =>
              // Phase 2I.1A section E -- a dispatch_message notification
              // with a known target navigates to the dispatch it's about
              // (Board auto-opens it via ?dispatch=, see kanban-board.tsx)
              // instead of just marking itself read in place. Read-marking
              // still happens (fire-and-forget, non-blocking, matching the
              // rest of this app's own toast-on-error-only pattern) so
              // acting on the notification also clears its unread state.
              // Every other notification type keeps the original
              // form/mark-read-only behavior, completely untouched.
              n.type === "dispatch_message" && n.entity_id ? (
                <Link
                  key={n.id}
                  href={`/dispatch/board?dispatch=${n.entity_id}`}
                  onClick={() => {
                    markNotificationRead(n.id).catch(() => {});
                  }}
                  className="flex w-full flex-col items-start gap-0.5 rounded-lg px-2.5 py-2.5 text-left transition-colors hover:bg-muted"
                >
                  <div className="flex w-full items-center gap-2">
                    {!n.read_at && <span className="size-1.5 shrink-0 rounded-full bg-primary" />}
                    <p className="flex-1 truncate text-sm font-medium">{n.title}</p>
                  </div>
                  {n.body && <p className="line-clamp-2 pl-3.5 text-xs text-muted-foreground">{n.body}</p>}
                </Link>
              ) : n.exception_id ? (
                // Phase 2P.6B -- an exception-sourced notification (0107:
                // opened/escalated/assigned/reassigned) navigates to the
                // Exception Center rather than just marking itself read.
                // Normal Exception Center RLS/role-guard still applies on
                // arrival -- a foreign-org or resolved-historical exception
                // is handled safely by that page, not by this link.
                <Link
                  key={n.id}
                  href={`/dispatch/exceptions?exception=${n.exception_id}`}
                  onClick={() => {
                    markNotificationRead(n.id).catch(() => {});
                  }}
                  className="flex w-full flex-col items-start gap-0.5 rounded-lg px-2.5 py-2.5 text-left transition-colors hover:bg-muted"
                >
                  <div className="flex w-full items-center gap-2">
                    {!n.read_at && <span className="size-1.5 shrink-0 rounded-full bg-primary" />}
                    <p className="flex-1 truncate text-sm font-medium">{n.title}</p>
                  </div>
                  {n.body && <p className="line-clamp-2 pl-3.5 text-xs text-muted-foreground">{n.body}</p>}
                </Link>
              ) : (
                <form key={n.id} action={markNotificationRead.bind(null, n.id)}>
                  <button
                    type="submit"
                    className="flex w-full flex-col items-start gap-0.5 rounded-lg px-2.5 py-2.5 text-left transition-colors hover:bg-muted"
                  >
                    <div className="flex w-full items-center gap-2">
                      {!n.read_at && <span className="size-1.5 shrink-0 rounded-full bg-primary" />}
                      <p className="flex-1 truncate text-sm font-medium">{n.title}</p>
                    </div>
                    {n.body && <p className="line-clamp-2 pl-3.5 text-xs text-muted-foreground">{n.body}</p>}
                  </button>
                </form>
              )
            )
          )}
        </div>
        <DropdownMenuSeparator className="m-0" />
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
