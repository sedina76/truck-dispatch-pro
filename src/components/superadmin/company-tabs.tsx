"use client";

import { useState } from "react";
import { cn } from "@/lib/utils";

const TABS = ["Overview", "Company Profile", "Admins & Credentials", "Subscription", "Billing", "Usage", "Audit History"] as const;
export type CompanyTab = (typeof TABS)[number];

// Local client-side tab switching -- all 7 panels are already rendered
// server-side in one page load (one set of queries, no per-tab
// navigation/refetch); this just shows/hides them, same "keep mounted,
// toggle visibility" convention as DesktopCollapsibleSection elsewhere in
// this app.
export function CompanyTabs({ panels, initialTab }: { panels: Record<CompanyTab, React.ReactNode>; initialTab?: CompanyTab }) {
  const [active, setActive] = useState<CompanyTab>(initialTab ?? "Overview");

  return (
    <div>
      <div className="flex gap-1 overflow-x-auto border-b border-slate-800">
        {TABS.map((tab) => (
          <button
            key={tab}
            type="button"
            onClick={() => setActive(tab)}
            className={cn(
              "shrink-0 whitespace-nowrap border-b-2 px-3 py-2.5 text-[13px] font-medium transition-colors",
              active === tab ? "border-blue-500 text-blue-400" : "border-transparent text-slate-400 hover:text-slate-200"
            )}
          >
            {tab}
          </button>
        ))}
      </div>
      <div className="pt-5">
        {TABS.map((tab) => (
          <div key={tab} className={active === tab ? "block" : "hidden"}>
            {panels[tab]}
          </div>
        ))}
      </div>
    </div>
  );
}
