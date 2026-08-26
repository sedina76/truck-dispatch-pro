import Link from "next/link";
import { AuthShell } from "@/components/auth/auth-shell";
import { AuthCard } from "@/components/auth/auth-card";
import { LoginForm } from "./login-form";

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ confirmEmail?: string; reset?: string }>;
}) {
  const { confirmEmail, reset } = await searchParams;

  return (
    <AuthShell richEnvironment>
      {/* Asymmetric composition (creative-director pass): hero copy
          left-aligned in its own lane, card anchored right -- not
          centered/stacked. The environment (road, truck, route, status
          chip) fills the space between and behind them rather than the
          page reading as separate stacked sections. Card position is a
          simple flex row on large screens; both stack to a single column
          below lg, and the hero copy is dropped entirely there (see the
          hidden lg:block below) so the phone view goes straight to
          authentication. */}
      <div className="mx-auto flex w-full max-w-6xl flex-1 flex-col items-center justify-center gap-10 lg:flex-row lg:items-center lg:justify-between lg:gap-8">
        <div className="hidden max-w-xl lg:block">
          <h1 className="text-4xl font-bold leading-[1.15] text-white xl:text-[44px]">
            Run your trucking operation from <span className="text-primary">one place.</span>
          </h1>
          <p className="mt-5 max-w-sm text-[15px] leading-relaxed text-white/50">
            Dispatch, drivers, GPS tracking, billing, compliance, and customer communication -- built for real freight operations.
          </p>
        </div>

        <AuthCard>
          <div className="space-y-5">
            <div>
              <h2 className="text-2xl font-bold tracking-tight text-[#1a1a18]">Welcome back</h2>
              <p className="mt-1 text-sm text-[#6b6b64]">Sign in to Truck Dispatch Pro</p>
            </div>

            {confirmEmail && (
              <p className="rounded-md border border-[#e4e4e0] bg-white p-3 text-sm text-[#4a4a44]">
                Check your email to confirm your account before signing in.
              </p>
            )}
            {reset && (
              <p className="rounded-md border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-700">
                Your password has been updated. Sign in with your new password.
              </p>
            )}

            <LoginForm />

            <p className="text-center text-sm text-[#6b6b64]">
              No account?{" "}
              <Link href="/signup" className="font-medium text-[#1c54b8] hover:underline">
                Create one
              </Link>
            </p>

            <div className="border-t border-[#e4e4e0] pt-4 text-center text-sm text-[#6b6b64]">
              <p>
                Driver?{" "}
                <Link href="/driver-portal/login" className="font-medium text-[#1c54b8] hover:underline">
                  Driver Sign In
                </Link>
              </p>
            </div>
            {/* Phase 2Q.2: "Apply for Employment" removed from the main
                entry point (business decision -- carrier-invited
                onboarding, initiated from Drivers -> Invite Driver, is now
                the primary/authoritative driver onboarding workflow). The
                route, its data, and every existing driver_applications row
                are untouched -- only this link is gone. Also: the public
                submit route currently resolves ALL applicants to whichever
                organization was created first (a real single-tenant
                shortcut, see src/app/api/driver-application/submit/
                route.ts's own comment), so leaving it linked from a
                multi-tenant login page would silently misroute a real
                applicant to the wrong company -- see 2Q.2 report Section 3. */}
          </div>
        </AuthCard>
      </div>
    </AuthShell>
  );
}
