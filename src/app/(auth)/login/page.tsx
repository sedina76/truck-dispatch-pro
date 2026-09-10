import Link from "next/link";
import { BarChart3, FileCheck2, MapPin } from "lucide-react";
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
      <div className="mx-auto flex w-full max-w-[1480px] flex-1 flex-col items-center justify-center gap-10 lg:flex-row lg:items-center lg:justify-between lg:gap-12 xl:px-4">
        <div className="hidden max-w-[680px] lg:block lg:flex-1">
          <h1 className="max-w-[650px] text-[42px] font-bold leading-[1.13] tracking-[-0.025em] text-white xl:text-[52px]">
            Run your trucking operation from <span className="text-primary">one place.</span>
          </h1>
          <p className="mt-6 max-w-[600px] text-[16px] leading-7 text-white/58">
            Dispatch, drivers, GPS tracking, billing, compliance, and customer communication -- built for real freight operations.
          </p>

          <div className="mt-9 flex items-center gap-7 text-sm text-white/85 xl:gap-10">
            <div className="flex items-center gap-3"><span className="flex size-11 items-center justify-center rounded-xl border border-[#2680ff]/35 bg-[#2680ff]/10 text-[#39a0ff]"><BarChart3 className="size-5" /></span><span>Live dispatch<br />visibility</span></div>
            <div className="h-10 w-px bg-white/15" />
            <div className="flex items-center gap-3"><span className="flex size-11 items-center justify-center rounded-xl border border-[#2680ff]/35 bg-[#2680ff]/10 text-[#39a0ff]"><MapPin className="size-5" /></span><span>Driver GPS<br />tracking</span></div>
            <div className="h-10 w-px bg-white/15" />
            <div className="flex items-center gap-3"><span className="flex size-11 items-center justify-center rounded-xl border border-[#2680ff]/35 bg-[#2680ff]/10 text-[#39a0ff]"><FileCheck2 className="size-5" /></span><span>Billing &amp;<br />compliance</span></div>
          </div>
        </div>

        <AuthCard dark className="lg:w-[460px]">
          <div className="space-y-6">
            <div>
              <h2 className="text-[32px] font-bold tracking-tight text-white">Welcome back</h2>
              <p className="mt-1.5 text-[15px] text-white/55">Sign in to Truck Dispatch Pro</p>
            </div>

            {confirmEmail && (
              <p className="rounded-md border border-white/15 bg-white/5 p-3 text-sm text-white/80">
                Check your email to confirm your account before signing in.
              </p>
            )}
            {reset && (
              <p className="rounded-md border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-700">
                Your password has been updated. Sign in with your new password.
              </p>
            )}

            <LoginForm />

            <p className="text-center text-sm text-white/60">
              No account?{" "}
              <Link href="/signup" className="font-medium text-[#39a0ff] hover:text-[#75bdff] hover:underline">
                Create one
              </Link>
            </p>

            <div className="border-t border-white/15 pt-5 text-center text-sm text-white/60">
              <p>
                Driver?{" "}
                <Link href="/driver-portal/login" className="font-medium text-[#39a0ff] hover:text-[#75bdff] hover:underline">
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
