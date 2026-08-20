"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/utils";

// Phase 2G.5: the Billing workspace's own internal navigation, so a user
// inside any financial page never needs the main sidebar to move between
// financial workflows (spec section 5). Visually identical to
// DesktopWorkspaceTabs (same document-tab treatment) but deliberately a
// separate component -- DesktopWorkspaceTabs' "active" rule is
// `i === tabs.length - 1` (last tab wins), correct for its actual job
// elsewhere (breadcrumb-style trails like "Invoices" -> "INV-000004") but
// wrong here, where every page in a shared, order-independent tab row
// needs to highlight ITSELF. This component matches on pathname instead.
//
// Every route below already exists and is unchanged -- this is
// presentation/navigation only. Statements is included even though the
// original spec's suggested tab list didn't name it: it already reuses
// get_party_ar_summary() and the same AR aging function as Collections and
// is party/AR-focused (open balance, period activity, aging) -- it is the
// same financial workspace, not a separate module, and omitting a real,
// already-built page here would just hide it instead of organizing it.
const BILLING_TABS = [
  { label: "Overview", href: "/billing" },
  { label: "Ready to Bill", href: "/billing/ready-to-bill" },
  { label: "Invoices", href: "/invoices" },
  { label: "Payments", href: "/payments" },
  { label: "Accounts Receivable", href: "/accounts-receivable" },
  { label: "Collections", href: "/collections" },
  { label: "Statements", href: "/statements" },
];

export function BillingSubnav() {
  const pathname = usePathname();
  return (
    // Phase 2G.6: `overflow-x-auto` + `shrink-0` on every tab -- at phone
    // widths 7 tabs don't fit, and the instruction was explicit not to
    // wrap them into multiple rows. This scrolls horizontally instead,
    // same active-tab styling as desktop, no separate compact-select
    // variant needed (a scrollable single row reads clearly enough down
    // to 390px -- verified via screenshot).
    <div className="flex h-7 shrink-0 items-center gap-0.5 overflow-x-auto border-b border-desktop-border bg-desktop-bg px-1.5 pt-1">
      {BILLING_TABS.map((tab) => {
        const active = tab.href === "/billing" ? pathname === "/billing" : pathname.startsWith(tab.href);
        return (
          <Link
            key={tab.href}
            href={tab.href}
            className={cn(
              "flex h-6 shrink-0 items-center whitespace-nowrap rounded-t-sm border border-b-0 px-3 text-[11.5px] font-medium",
              active
                ? "border-desktop-border bg-desktop-panel text-desktop-text"
                : "border-transparent text-muted-foreground hover:bg-desktop-muted"
            )}
          >
            {tab.label}
          </Link>
        );
      })}
    </div>
  );
}
