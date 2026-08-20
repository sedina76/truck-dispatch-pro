import { TruckSilhouette } from "@/components/auth/truck-silhouette";

// The auth canvas's actual visual centerpiece -- a night-interstate scene
// (perspective road converging to a glowing horizon, a rim-lit truck
// silhouette, ground haze) built from layered gradients/SVG.
//
// `rich`: the login screen gets the full scene (truck + one operational
// status chip riding the road's own route line). Every other auth screen
// gets `rich=false` -- just the road/horizon/haze, no truck or chip.
//
// Iterated twice on screenshot review: v1 had the chip colliding with the
// hero paragraph; v2 fixed that but clipped the truck against the left
// and bottom edges and had FOUR near-parallel diagonal lines (2 road
// edges + a separate "route" line duplicating the road's own center
// line) reading as visual clutter. This version: the road's own dashed
// center line IS the route (no duplicate), and the truck is fully
// inset -- nothing touches the canvas edge.
export function AuthEnvironment({ rich = false }: { rich?: boolean }) {
  return (
    <div className="pointer-events-none absolute inset-0 overflow-hidden" aria-hidden="true">
      {/* Horizon glow -- doubles as ambient backlighting for the login card. */}
      <div
        className="absolute right-[6%] top-[14%] h-[460px] w-[640px] opacity-70 blur-[100px]"
        style={{ background: "radial-gradient(circle, #2c4a94 0%, transparent 70%)" }}
      />
      <div
        className="absolute right-[16%] top-[22%] h-[110px] w-[320px] opacity-35 blur-[60px]"
        style={{ background: "radial-gradient(ellipse, #c98a4b 0%, transparent 75%)" }}
      />

      {/* Perspective road -- a real visible bed + ONE dashed center lane
          line that IS the dispatch route (not duplicated), converging to
          a bright vanishing point. */}
      <svg className="absolute inset-0 h-full w-full" preserveAspectRatio="none" viewBox="0 0 1440 900" fill="none">
        <defs>
          <linearGradient id="road-fade" x1="0" y1="900" x2="0" y2="260" gradientUnits="userSpaceOnUse">
            <stop offset="0" stopColor="#111b32" stopOpacity="0.85" />
            <stop offset="1" stopColor="#111b32" stopOpacity="0.1" />
          </linearGradient>
        </defs>
        <path d="M -80 900 L 560 900 L 1010 250 L 960 250 Z" fill="url(#road-fade)" />
        <path d="M -80 900 L 1010 250" stroke="#4a6cc0" strokeOpacity="0.4" strokeWidth="1.5" />
        <path d="M 560 900 L 960 250" stroke="#4a6cc0" strokeOpacity="0.4" strokeWidth="1.5" />
        <path d="M 260 900 L 985 250" stroke="#7fa0f5" strokeOpacity="0.55" strokeWidth="2.5" strokeDasharray="30 24" />
        <circle cx="985" cy="250" r="4" fill="#9db6f7" />
        <circle cx="985" cy="250" r="16" fill="#7fa0f5" fillOpacity="0.25" />
      </svg>

      <div className="absolute bottom-0 left-0 h-[240px] w-[70%] opacity-70 blur-[55px]" style={{ background: "linear-gradient(0deg, #05070d 0%, transparent 100%)" }} />

      {rich && (
        <>
          {/* lg+ only -- found live: below lg the login card stacks to a
              single centered column and sits directly on top of both the
              truck and the chip (the chip's own text was rendering
              half-hidden behind the card's edge). Spec: "remove
              unnecessary operational decorations" on mobile anyway -- the
              road perspective + horizon glow above are NOT conditional on
              `rich`, so mobile still keeps a small amount of atmosphere
              without either element fighting the card for space. */}
          <TruckSilhouette className="absolute bottom-[9%] left-[4%] hidden w-[46%] max-w-[560px] lg:block" />

          {/* One operational status chip. Pinned with `top` (not
              `bottom`) at a fixed 70% down the viewport -- found live
              across two prior passes that ANY position sharing the same
              vertical band as the hero paragraph collides with it, since
              that text's height varies with wrapping/viewport width.
              70% down is safely below where that text can reasonably
              reach, and sits directly beside the truck's cab. */}
          <div className="absolute left-[7%] top-[70%] hidden w-56 rounded-md border border-white/10 bg-[#070a12]/85 px-3.5 py-3 shadow-lg backdrop-blur-sm lg:block">
            <div className="flex items-center gap-1.5 text-[11px] font-semibold tracking-wide text-white/90">
              <span className="size-1.5 rounded-full bg-emerald-400" />
              LOAD #10482 &middot; IN TRANSIT
            </div>
            <div className="mt-2 flex items-center justify-between text-[11px] text-white/55">
              <span className="tabular-nums">Dallas, TX</span>
              <span>&rarr;</span>
              <span className="tabular-nums">Columbus, OH</span>
            </div>
            <div className="mt-2 flex items-center justify-between border-t border-white/10 pt-2 text-[11px]">
              <span className="tabular-nums text-white/70">ETA 4:35 PM</span>
              <span className="font-medium text-emerald-400">ON SCHEDULE</span>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
