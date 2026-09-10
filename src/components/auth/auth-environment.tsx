import Image from "next/image";

// The login canvas uses the commissioned night-interstate artwork. Secondary
// auth screens keep the lighter-weight CSS/SVG atmosphere below so they do
// not download the hero asset unnecessarily.
//
// `rich`: full truck + route artwork for login. `false`: ambient road scene.
export function AuthEnvironment({ rich = false }: { rich?: boolean }) {
  if (rich) {
    return (
      <div className="pointer-events-none absolute inset-0 overflow-hidden" aria-hidden="true">
        <Image
          src="/images/auth-truck-route-bg.png"
          alt=""
          fill
          priority
          sizes="100vw"
          className="object-cover object-center"
        />
        <div className="absolute inset-0 bg-[linear-gradient(90deg,rgba(3,8,18,.18)_0%,rgba(3,8,18,.08)_48%,rgba(3,8,18,.42)_100%)]" />
        <div className="absolute inset-x-0 top-0 h-56 bg-gradient-to-b from-[#030812]/75 to-transparent" />
        <div className="absolute inset-x-0 bottom-0 h-32 bg-gradient-to-t from-[#030812]/60 to-transparent" />
      </div>
    );
  }

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

    </div>
  );
}
