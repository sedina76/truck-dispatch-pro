import Link from "next/link";
import { ArrowLeft } from "lucide-react";
import { Logo } from "@/components/brand/logo";
import { AuthEnvironment } from "@/components/auth/auth-environment";
import { cn } from "@/lib/utils";

// Shared shell for every auth screen. Creative-director pass: removed the
// generic trust-bar footer entirely (spec: "every visible element must
// earn its place" -- it read as template filler and this composition's
// own visual quality now carries the credibility signal instead), gave
// the brand real presence in the header, and replaced the flat decorative
// background with AuthEnvironment's actual night-interstate scene. Still
// a deliberately FIXED dark canvas regardless of the visitor's OS
// light/dark preference (see AuthCard's own header comment).
export function AuthShell({
  children,
  richEnvironment = false,
  centered = false,
}: {
  children: React.ReactNode;
  richEnvironment?: boolean;
  /** Every secondary screen (signup, verify-email, forgot-password, reset-password, forgot-email, onboarding) just needs its card centered -- no asymmetric hero composition, that's login-only. */
  centered?: boolean;
}) {
  return (
    <div className="relative flex min-h-screen flex-col overflow-hidden bg-[#05070d]" style={{ backgroundImage: "linear-gradient(160deg, #05070d 0%, #0a0f1c 60%, #070a12 100%)" }}>
      <AuthEnvironment rich={richEnvironment} />

      {/* The logo and "Home" both lead back to the public homepage (a signed-in
          visitor is sent on to their dashboard from there). */}
      <header className="relative z-10 flex items-center justify-between gap-4 px-6 py-6 sm:px-10 sm:py-8 xl:px-16">
        <Link href="/" aria-label="Truck Dispatch Pro home" className="rounded-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#39a0ff]/60">
          <span className="sm:hidden">
            <Logo dark />
          </span>
          <span className="hidden sm:block">
            <Logo dark subtitle size="lg" />
          </span>
        </Link>
        <Link
          href="/"
          className="inline-flex items-center gap-1.5 whitespace-nowrap rounded-md border border-white/15 bg-white/[0.04] px-3 py-2 text-[13.5px] font-medium text-white/80 transition-colors hover:border-white/30 hover:bg-white/10 hover:text-white"
          data-testid="back-home"
        >
          <ArrowLeft className="size-4" /> Home
        </Link>
      </header>

      <main className={cn("relative z-10 flex flex-1 flex-col px-4 pb-10 sm:px-8 xl:px-14", centered && "items-center justify-center")}>{children}</main>
    </div>
  );
}
