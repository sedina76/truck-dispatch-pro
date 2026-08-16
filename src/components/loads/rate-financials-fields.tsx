"use client";

import { useEffect, useState } from "react";

// Revenue/Mile is a live, purely-arithmetic display (rate / miles) -- not a
// duplicate of the canonical profitability calculator. It listens to the
// real #rate (this section) and #total_miles (Equipment & Freight section)
// inputs by id via plain DOM events, rather than owning/duplicating either
// field -- both stay ordinary uncontrolled FormFields elsewhere on the page.
//
// Transportation Cost/Margin are deliberately NOT shown here: before a
// dispatch (carrier or driver) is assigned, there is no real cost basis to
// compute them from (get_load_profitability's own cost hierarchy depends
// on dispatch/settlement data that doesn't exist yet at load-creation
// time) -- fabricating a number here would violate spec section 9 ("Never
// fabricate transportation cost"). The real figures appear on the Load
// Detail page's Profitability section (LoadProfitabilitySection, reusing
// the canonical get_load_profitability() RPC) once a dispatch exists.
export function RevenuePerMileLive() {
  const [perMile, setPerMile] = useState<number | null>(null);

  useEffect(() => {
    const rateEl = document.getElementById("rate") as HTMLInputElement | null;
    const milesEl = document.getElementById("total_miles") as HTMLInputElement | null;
    if (!rateEl || !milesEl) return;

    function recompute() {
      const rate = Number(rateEl!.value);
      const miles = Number(milesEl!.value);
      setPerMile(rateEl!.value && milesEl!.value && miles > 0 && !Number.isNaN(rate) ? rate / miles : null);
    }
    recompute();
    rateEl.addEventListener("input", recompute);
    milesEl.addEventListener("input", recompute);
    return () => {
      rateEl.removeEventListener("input", recompute);
      milesEl.removeEventListener("input", recompute);
    };
  }, []);

  return (
    <div className="space-y-1">
      <label className="text-[12px] font-medium text-desktop-text">Revenue / Mile</label>
      <div className="flex h-8 items-center rounded-sm border border-desktop-border bg-desktop-muted px-2.5 text-[13px] text-desktop-text-muted">
        {perMile != null ? `$${perMile.toFixed(2)} / mi (estimate)` : "-- enter rate and miles"}
      </div>
    </div>
  );
}
