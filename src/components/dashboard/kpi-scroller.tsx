"use client";

import { useRef } from "react";
import { KpiTile, type KpiTileData } from "@/components/dashboard/kpi-tile";

export function KpiScroller({ tiles }: { tiles: KpiTileData[] }) {
  const scrollerRef = useRef<HTMLDivElement>(null);

  // Desktop users scroll with a vertical wheel by default; a horizontal-only
  // strip feels broken unless that vertical intent gets redirected here.
  // Trackpads (which already send deltaX) pass through untouched.
  function onWheel(e: React.WheelEvent<HTMLDivElement>) {
    if (Math.abs(e.deltaY) <= Math.abs(e.deltaX)) return;
    const el = scrollerRef.current;
    if (!el) return;
    e.preventDefault();
    el.scrollLeft += e.deltaY;
  }

  return (
    <div className="sticky top-0 z-20 -mx-4 border-b border-desktop-border bg-background/95 px-4 py-2">
      <div className="relative">
        <div
          ref={scrollerRef}
          onWheel={onWheel}
          className="no-scrollbar flex gap-2 overflow-x-auto scroll-smooth"
        >
          {tiles.map((tile) => (
            // Below the xl breakpoint each card keeps a fixed minimum width and
            // the row scrolls horizontally; at xl+ the cards grow to share the
            // row equally so all 8 fit on one line without wrapping.
            <div key={tile.id} className="w-36 shrink-0 xl:w-0 xl:flex-1 xl:shrink">
              <KpiTile data={tile} />
            </div>
          ))}
        </div>
        <div className="pointer-events-none absolute inset-y-0 left-0 w-8 bg-gradient-to-r from-background to-transparent xl:hidden" />
        <div className="pointer-events-none absolute inset-y-0 right-0 w-8 bg-gradient-to-l from-background to-transparent xl:hidden" />
      </div>
    </div>
  );
}
