import { cn } from "@/lib/utils";

// The Truck Dispatch Pro mark: a route from a start point to a glowing
// destination on a dark navy tile. The same drawing is used for the browser
// tab / home-screen icons (src/app/icon.png, apple-icon.png, favicon.ico,
// public/icon-192.png, public/icon-512.png -- made from public/brand/mark.svg).
export function BrandMark({ className, title }: { className?: string; title?: string }) {
  return (
    <svg
      viewBox="0 0 512 512"
      className={cn("shrink-0", className)}
      role={title ? "img" : undefined}
      aria-label={title}
      aria-hidden={title ? undefined : true}
      data-testid="brand-mark"
    >
      <defs>
        <linearGradient id="tdp-mark-bg" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#14204a" />
          <stop offset="1" stopColor="#070b18" />
        </linearGradient>
      </defs>
      <rect width="512" height="512" rx="112" fill="url(#tdp-mark-bg)" />
      <path d="M132 388 C132 290 252 316 256 256 C260 196 380 222 380 124" fill="none" stroke="#3a7bff" strokeWidth="46" strokeLinecap="round" />
      <circle cx="132" cy="388" r="44" fill="#fff" />
      <circle cx="132" cy="388" r="17" fill="#0e1736" />
      <circle cx="380" cy="124" r="86" fill="#39a0ff" opacity="0.22" />
      <circle cx="380" cy="124" r="56" fill="#39a0ff" />
      <circle cx="380" cy="124" r="22" fill="#fff" />
    </svg>
  );
}
