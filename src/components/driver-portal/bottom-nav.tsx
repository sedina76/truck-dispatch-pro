"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { Home, Truck, FileText, Receipt, Wallet, History } from "lucide-react";
import { cn } from "@/lib/utils";

const ITEMS = [
  { href: "/driver-portal", label: "Home", icon: Home },
  { href: "/driver-portal/trip", label: "Trip", icon: Truck },
  { href: "/driver-portal/documents", label: "Docs", icon: FileText },
  { href: "/driver-portal/expenses", label: "Expenses", icon: Receipt },
  { href: "/driver-portal/settlements", label: "Pay", icon: Wallet },
  { href: "/driver-portal/history", label: "History", icon: History },
];

// Bottom tab bar -- the mobile-native navigation pattern (spec section 27),
// not the staff desktop sidebar. Hidden on the login screen (nothing to
// navigate to before authenticating). 44px+ touch targets throughout.
export function DriverPortalBottomNav() {
  const pathname = usePathname();
  if (pathname === "/driver-portal/login") return null;

  return (
    <nav className="fixed inset-x-0 bottom-0 z-20 border-t border-border bg-card/95 backdrop-blur supports-[backdrop-filter]:bg-card/80">
      <div className="mx-auto flex w-full max-w-md items-stretch justify-between px-1">
        {ITEMS.map((item) => {
          const active = item.href === "/driver-portal" ? pathname === item.href : pathname.startsWith(item.href);
          return (
            <Link
              key={item.href}
              href={item.href}
              className={cn(
                "flex min-w-11 flex-1 flex-col items-center justify-center gap-0.5 py-2 text-[10.5px] font-medium",
                active ? "text-primary" : "text-muted-foreground"
              )}
            >
              <item.icon className="size-5" />
              {item.label}
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
