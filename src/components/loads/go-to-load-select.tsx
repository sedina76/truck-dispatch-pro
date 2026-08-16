"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { ArrowRight } from "lucide-react";
import { Button } from "@/components/ui/button";

// Driver/Carrier Profile -> "Share External Profile" (spec sections 16/17)
// requires choosing the associated load first -- there is no generic,
// shipment-less external profile in this pass. This is a plain load
// picker that hands off to the Load Detail page, where the one real Share
// Profile dialog lives (spec section 18: Load Detail is "the primary
// workflow"). Kept deliberately thin rather than duplicating the whole
// generate/preview/email dialog a second time on Driver/Carrier profiles.
export function GoToLoadSelect({ loads }: { loads: { id: string; label: string }[] }) {
  const router = useRouter();
  const [selected, setSelected] = useState(loads[0]?.id ?? "");

  return (
    <div className="flex items-center gap-2">
      <select
        value={selected}
        onChange={(e) => setSelected(e.target.value)}
        className="h-7 flex-1 rounded-sm border border-desktop-border bg-desktop-panel px-2 text-[12.5px] text-desktop-text outline-none focus-visible:border-primary"
      >
        {loads.map((l) => (
          <option key={l.id} value={l.id}>
            {l.label}
          </option>
        ))}
      </select>
      <Button
        type="button"
        size="sm"
        variant="outline"
        className="h-7 gap-1 px-2.5 text-xs"
        disabled={!selected}
        onClick={() => router.push(`/loads/${selected}`)}
      >
        Share for This Load
        <ArrowRight className="size-3.5" />
      </Button>
    </div>
  );
}
