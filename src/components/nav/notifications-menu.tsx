"use client";

import { Bell, BellRing, CheckCheck } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuTrigger,
  DropdownMenuSeparator,
} from "@/components/ui/dropdown-menu";
import { markAllNotificationsRead, markNotificationRead } from "@/lib/actions/notifications";

type NotificationRow = {
  id: string;
  title: string;
  body: string | null;
  type: string;
  read_at: string | null;
  created_at: string;
};

export function NotificationsMenu({ notifications }: { notifications: NotificationRow[] }) {
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
            notifications.map((n) => (
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
            ))
          )}
        </div>
        <DropdownMenuSeparator className="m-0" />
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
