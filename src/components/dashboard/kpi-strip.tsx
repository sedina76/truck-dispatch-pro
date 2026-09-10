"use client";

import { useRef } from "react";
import { KpiTile, type KpiTileData } from "@/components/dashboard/kpi-tile";

// Primary dashboard KPI strip -- ONE horizontal row.
//   xl and up (large desktop): all 8 cards flex to equal width and share
//     the row, no scrollbar.
//   below xl (laptop / tablet / mobile): each card keeps a readable fixed
//     width and the strip itself scrolls horizontally (native touch/swipe
//     via overflow-x-auto; mouse-wheel is redirected below). overscroll-x
//     is contained so only this strip scrolls -- the rest of the dashboard
//     never moves sideways.
export function KpiStrip({ tiles }: { tiles: KpiTileData[] }) {
  const ref = useRef<HTMLDivElement>(null);

  function onWheel(e: React.WheelEvent<HTMLDivElement>) {
    // Vertical-only wheel (mouse) -> scroll the strip. Trackpads already
    // send deltaX and pass straight through.
    if (Math.abs(e.deltaY) <= Math.abs(e.deltaX)) return;
    const el = ref.current;
    if (!el || el.scrollWidth <= el.clientWidth) return; // nothing to scroll (xl fits all 8)
    e.preventDefault();
    el.scrollLeft += e.deltaY;
  }

  if (tiles.length === 0) return null;

  return (
    <div className="relative">
      <div
        ref={ref}
        onWheel={onWheel}
        className="no-scrollbar flex gap-2 overflow-x-auto overscroll-x-contain scroll-smooth"
      >
        {tiles.map((tile) => (
          <div key={tile.id} className="w-36 shrink-0 xl:w-0 xl:min-w-0 xl:flex-1 xl:shrink">
            <KpiTile data={tile} />
          </div>
        ))}
      </div>
      {/* Edge fades: a visual hint that the strip scrolls. Hidden at xl,
          where every card already fits. */}
      <div className="pointer-events-none absolute inset-y-0 left-0 w-6 bg-gradient-to-r from-background to-transparent xl:hidden" />
      <div className="pointer-events-none absolute inset-y-0 right-0 w-6 bg-gradient-to-l from-background to-transparent xl:hidden" />
    </div>
  );
}
