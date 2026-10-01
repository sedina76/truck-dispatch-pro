"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { Home, Truck, FileText, Receipt, Wallet, History, MessageSquare, AlertTriangle, X } from "lucide-react";
import { cn } from "@/lib/utils";
import { getMyPortalAlerts, type MyPortalAlerts } from "@/app/driver-portal/actions";
import { decideMessageAlert } from "@/lib/notify/message-alert";
import { installChimeUnlock, playMessageChime, playRejectedAlert } from "@/lib/notify/message-chime";

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

  // Phase 2I.1A section K -- lightweight 20s polling via a narrow server
  // action, never a websocket/Realtime channel. Skipped entirely on the
  // login screen (no session to query). Guarded against overlap; stops on
  // unmount. Also drives the new-message chime: this nav lives in the
  // portal layout, so it hears new dispatch messages on EVERY portal
  // screen. The first check only records what's already unread, so old
  // messages never chime on page load.
  const chimeBaseline = useRef<string | null | undefined>(undefined);
  // Separate baseline for a rejected POD, so it has its own (different)
  // alert sound and the two never suppress each other.
  const rejectBaseline = useRef<string | null | undefined>(undefined);
  const [rejectedPod, setRejectedPod] = useState<MyPortalAlerts["rejectedPod"]>(null);
  const [dismissedRejection, setDismissedRejection] = useState<string | null>(null);
  useEffect(() => installChimeUnlock(), []);
  useEffect(() => {
    if (isLoginPage) return;
    let cancelled = false;
    let inFlight = false;
    const check = () => {
      if (inFlight || cancelled) return;
      inFlight = true;
      getMyPortalAlerts()
        .then(({ messages, rejectedPod: rejected }) => {
          if (cancelled) return;
          setUnreadMessageCount(messages.count);
          setRejectedPod(rejected);
          const reject = decideMessageAlert(rejectBaseline.current, { count: rejected ? 1 : 0, latestAt: rejected?.rejectedAt ?? null });
          rejectBaseline.current = reject.baseline;
          const message = decideMessageAlert(chimeBaseline.current, messages);
          chimeBaseline.current = message.baseline;
          // A rejection outranks a message in the same check -- one sound at a time.
          if (reject.chime) playRejectedAlert();
          else if (message.chime) playMessageChime();
        })
        .catch(() => {})
        .finally(() => {
          inFlight = false;
        });
    };
    check();
    const interval = setInterval(check, 20000);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [isLoginPage]);

  if (isLoginPage) return null;

  // Phase 2I.1A section H -- hidden at 0, capped display at "99+" so a
  // pathological count can never widen/overflow the tab bar.
  const badgeLabel = unreadMessageCount > 99 ? "99+" : String(unreadMessageCount);

  const showRejectionBanner = rejectedPod && dismissedRejection !== rejectedPod.rejectedAt && pathname !== "/driver-portal/documents";

  return (
    <>
    {showRejectionBanner && (
      <div className="fixed inset-x-0 bottom-16 z-20 px-3 pb-2">
        <div className="mx-auto flex w-full max-w-md items-start gap-2 rounded-xl border border-danger/40 bg-danger/10 p-3 text-sm shadow-lg backdrop-blur" role="alert">
          <AlertTriangle className="mt-0.5 size-4 shrink-0 text-danger" />
          <Link href="/driver-portal/documents" className="min-w-0 flex-1">
            <span className="block font-semibold text-danger">Proof of Delivery rejected</span>
            <span className="block text-xs text-foreground">
              {rejectedPod.reason ? `${rejectedPod.reason} -- ` : ""}tap to upload a new one.
            </span>
          </Link>
          <button type="button" aria-label="Dismiss" onClick={() => setDismissedRejection(rejectedPod.rejectedAt)} className="-m-1 p-1 text-muted-foreground">
            <X className="size-4" />
          </button>
        </div>
      </div>
    )}
    <nav className="fixed inset-x-0 bottom-0 z-20 border-t border-border bg-card/95 backdrop-blur supports-[backdrop-filter]:bg-card/80">
      <div className="mx-auto flex w-full max-w-md items-stretch justify-between px-1">
        {ITEMS.map((item) => {
          const active = item.href === "/driver-portal" ? pathname === item.href : pathname.startsWith(item.href);
          const showBadge = item.href === "/driver-portal/messages" && unreadMessageCount > 0;
          const showRejectDot = item.href === "/driver-portal/documents" && Boolean(rejectedPod);
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
                {showRejectDot && <span aria-label="A document was rejected" className="absolute -right-1.5 -top-1 size-2.5 rounded-full bg-danger" />}
              </span>
              {item.label}
            </Link>
          );
        })}
      </div>
    </nav>
    </>
  );
}
