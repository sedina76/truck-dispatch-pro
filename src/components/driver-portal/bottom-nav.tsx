"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { Home, Truck, FileText, Receipt, Wallet, History, MessageSquare } from "lucide-react";
import { cn } from "@/lib/utils";
import { getMyUnreadMessageCount } from "@/app/driver-portal/actions";

const ITEMS = [
  { href: "/driver-portal", label: "Home", icon: Home },
  { href: "/driver-portal/trip", label: "Trip", icon: Truck },
  { href: "/driver-portal/messages", label: "Messages", icon: MessageSquare },
  { href: "/driver-portal/documents", label: "Docs", icon: FileText },
  { href: "/driver-portal/expenses", label: "Expenses", icon: Receipt },
  { href: "/driver-portal/settlements", label: "Pay", icon: Wallet },
  { href: "/driver-portal/history", label: "History", icon: History },
];

// Bottom tab bar -- the mobile-native navigation pattern (spec section 27),
// not the staff desktop sidebar. Hidden on the login screen (nothing to
// navigate to before authenticating). 44px+ touch targets throughout.
export function DriverPortalBottomNav({ initialUnreadMessageCount = 0 }: { initialUnreadMessageCount?: number }) {
  const pathname = usePathname();
  const isLoginPage = pathname === "/driver-portal/login";
  // Seeded from the server-rendered layout (no 0-then-flicker on first
  // paint), kept fresh client-side afterward.
  const [unreadMessageCount, setUnreadMessageCount] = useState(initialUnreadMessageCount);

  useEffect(() => {
    setUnreadMessageCount(initialUnreadMessageCount);
  }, [initialUnreadMessageCount]);

  // Phase 2I.1A section K -- lightweight 20s polling via the existing
  // narrow getMyUnreadMessageCount() server action, never a websocket/
  // Realtime channel. Skipped entirely on the login screen (no session to
  // query). Guarded against overlap; stops on unmount.
  useEffect(() => {
    if (isLoginPage) return;
    let cancelled = false;
    let inFlight = false;
    const interval = setInterval(() => {
      if (inFlight || cancelled) return;
      inFlight = true;
      getMyUnreadMessageCount()
        .then((count) => {
          if (!cancelled) setUnreadMessageCount(count);
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
  }, [isLoginPage]);

  if (isLoginPage) return null;

  // Phase 2I.1A section H -- hidden at 0, capped display at "99+" so a
  // pathological count can never widen/overflow the tab bar.
  const badgeLabel = unreadMessageCount > 99 ? "99+" : String(unreadMessageCount);

  return (
    <nav className="fixed inset-x-0 bottom-0 z-20 border-t border-border bg-card/95 backdrop-blur supports-[backdrop-filter]:bg-card/80">
      <div className="mx-auto flex w-full max-w-md items-stretch justify-between px-1">
        {ITEMS.map((item) => {
          const active = item.href === "/driver-portal" ? pathname === item.href : pathname.startsWith(item.href);
          const showBadge = item.href === "/driver-portal/messages" && unreadMessageCount > 0;
          return (
            <Link
              key={item.href}
              href={item.href}
              className={cn(
                "flex min-w-11 flex-1 flex-col items-center justify-center gap-0.5 py-2 text-[10.5px] font-medium",
                active ? "text-primary" : "text-muted-foreground"
              )}
            >
              <span className="relative inline-flex">
                <item.icon className="size-5" />
                {showBadge && (
                  <span
                    aria-label={`${unreadMessageCount} unread message${unreadMessageCount === 1 ? "" : "s"}`}
                    className="absolute -right-2 -top-1.5 flex h-3.5 min-w-3.5 items-center justify-center rounded-full bg-danger px-0.5 text-[8.5px] font-semibold leading-none text-danger-foreground"
                  >
                    {badgeLabel}
                  </span>
                )}
              </span>
              {item.label}
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
