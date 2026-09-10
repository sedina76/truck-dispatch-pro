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

      <header className="relative z-10 px-6 py-6 sm:px-10 sm:py-8 xl:px-16">
        <Logo dark subtitle size="lg" />
      </header>

      <main className={cn("relative z-10 flex flex-1 flex-col px-4 pb-10 sm:px-8 xl:px-14", centered && "items-center justify-center")}>{children}</main>
    </div>
  );
}
