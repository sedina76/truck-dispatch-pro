// PLACEHOLDER ASSET, built on lighting rather than illustrated detail.
// The previous draft was a flat, fully-outlined SVG (visible door lines,
// window panes, grille detail) and read as cheap/cartoonish -- this
// version is a near-silhouette: ONE dark body fill, no internal linework,
// and does all the "premium" work with a bright rim-light stroke along
// the roofline, a warm headlight glow, and small trailer marker lights --
// the same technique real nighttime fleet photography relies on. Still
// not a photograph, and still no real trucking asset exists in this repo.
//
// TO SWAP IN REAL PHOTOGRAPHY: commission or license a shot matching --
// modern Class 8 tractor-trailer, interstate/highway, evening/night,
// three-quarter or side angle, subtle blue ambient + warm headlight
// lighting, realistic (not futuristic/concept) -- and drop it at
// `public/images/auth-hero-truck.jpg` (roughly 1600x1000, transparent or
// dark-background-matched edges). Replace this component's return value
// with a plain Next <Image>; AuthEnvironment doesn't need to change.
export function TruckSilhouette({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 640 260" className={className} fill="none" aria-hidden="true">
      <defs>
        <linearGradient id="rim-light" x1="0" y1="0" x2="640" y2="0" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#8fb0f7" stopOpacity="0" />
          <stop offset="0.15" stopColor="#8fb0f7" stopOpacity="1" />
          <stop offset="0.55" stopColor="#8fb0f7" stopOpacity="0.7" />
          <stop offset="1" stopColor="#8fb0f7" stopOpacity="0.25" />
        </linearGradient>
        <radialGradient id="ground-shadow" cx="0.5" cy="0.5" r="0.5">
          <stop offset="0" stopColor="#000000" stopOpacity="0.55" />
          <stop offset="1" stopColor="#000000" stopOpacity="0" />
        </radialGradient>
        <radialGradient id="headlight-glow" cx="0.5" cy="0.5" r="0.5">
          <stop offset="0" stopColor="#ffd9a0" stopOpacity="0.9" />
          <stop offset="1" stopColor="#ffd9a0" stopOpacity="0" />
        </radialGradient>
      </defs>

      {/* ground contact shadow */}
      <ellipse cx="330" cy="235" rx="300" ry="16" fill="url(#ground-shadow)" />

      {/* trailer body -- one flat, near-black fill */}
      <path d="M 190 90 h 380 a 8 8 0 0 1 8 8 v 110 a 6 6 0 0 1 -6 6 h -382 z" fill="#131f3d" />
      {/* trailer roofline rim light */}
      <path d="M 192 90 h 378" stroke="url(#rim-light)" strokeWidth="3" strokeLinecap="round" />
      {/* trailer marker lights */}
      {[230, 300, 370, 440, 510].map((x) => (
        <circle key={x} cx={x} cy="97" r="2" fill="#5b84f0" fillOpacity="0.8" />
      ))}

      {/* cab -- one flat fill, silhouette only */}
      <path
        d="M 70 214 V 130 a 10 10 0 0 1 10 -10 h 66 a 22 22 0 0 1 18 9.5 l 34 47 a 10 10 0 0 1 2 6 v 31.5 z"
        fill="#131f3d"
      />
      {/* cab roofline + hood rim light */}
      <path d="M 80 120 h 66 a 22 22 0 0 1 15 7 M 70 214 V 150" stroke="url(#rim-light)" strokeWidth="2.5" strokeLinecap="round" fill="none" />

      {/* windshield -- faint glow, not a flat illustrated pane */}
      <path d="M 118 120 h 28 a 22 22 0 0 1 15 7 l 26 33 h -69 z" fill="#5b84f0" fillOpacity="0.12" />

      {/* headlight glow */}
      <circle cx="76" cy="196" r="14" fill="url(#headlight-glow)" />
      <circle cx="76" cy="196" r="3.5" fill="#ffe9c4" />

      {/* chassis line */}
      <path d="M 70 214 H 578" stroke="#050810" strokeWidth="10" strokeLinecap="round" />

      {/* wheels -- minimal, glowing rim arc only */}
      {[104, 150, 340, 400, 460, 520].map((cx) => (
        <g key={cx}>
          <circle cx={cx} cy="228" r="15" fill="#02040a" />
          <path d={`M ${cx - 13} 222 A 13 13 0 0 1 ${cx + 13} 222`} stroke="#5b84f0" strokeOpacity="0.4" strokeWidth="1.5" fill="none" />
        </g>
      ))}
    </svg>
  );
}
