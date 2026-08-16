"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/utils";

const TABS = [
  { label: "Alerts", href: "/compliance" },
  { label: "Insurance", href: "/compliance/insurance" },
  { label: "CDL", href: "/compliance/cdl" },
  { label: "DOT", href: "/compliance/dot" },
];

export function ComplianceNav() {
  const pathname = usePathname();

  return (
    <div className="inline-flex items-center gap-1 rounded-lg bg-muted p-1">
      {TABS.map((tab) => {
        const active = pathname === tab.href;
        return (
          <Link
            key={tab.href}
            href={tab.href}
            className={cn(
              "rounded-md px-3 py-1.5 text-sm font-medium transition-colors",
              active ? "bg-card text-foreground shadow-elevation-1" : "text-muted-foreground hover:text-foreground"
            )}
          >
            {tab.label}
          </Link>
        );
      })}
    </div>
  );
}
