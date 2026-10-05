import Link from "next/link";
import { CheckCircle2 } from "lucide-react";
import { AuthShell } from "@/components/auth/auth-shell";
import { AuthCard } from "@/components/auth/auth-card";
import { OAuthButtons } from "@/components/auth/oauth-buttons";
import { SignupForm } from "./signup-form";

// Same composition as sign-in: what you get on the left, the account card
// on the right (the left column drops away on phones). Claims stay
// factual -- the 30-day, no-card trial is the real Stripe policy
// (lib/stripe/checkout.ts TRIAL_PERIOD_DAYS).
const POINTS = [
  "Dispatch board, live GPS tracking and ETAs",
  "Invoices, factoring and dispatch fee billing",
  "Carrier onboarding with e-signed agreements",
  "Driver app for documents, expenses and fuel",
];

export default function SignupPage() {
  return (
    <AuthShell richEnvironment>
      <div className="mx-auto flex w-full max-w-[1480px] flex-1 flex-col items-center justify-center gap-10 lg:flex-row lg:items-center lg:justify-between lg:gap-12 xl:px-4">
        <div className="hidden max-w-[640px] lg:block lg:flex-1">
          <p className="text-[13px] font-semibold uppercase tracking-[0.14em] text-[#39a0ff]">30-day free trial · no credit card</p>
          <h1 className="mt-4 max-w-[620px] text-[42px] font-bold leading-[1.13] tracking-[-0.025em] text-white xl:text-[50px]">
            Set up your dispatch company <span className="text-primary">in minutes.</span>
          </h1>
          <ul className="mt-8 space-y-3.5 text-[16px] text-white/80">
            {POINTS.map((p) => (
              <li key={p} className="flex items-center gap-3">
                <CheckCircle2 className="size-5 shrink-0 text-[#39a0ff]" />
                {p}
              </li>
            ))}
          </ul>
        </div>

        <AuthCard dark className="lg:w-[460px]">
          <div className="space-y-6">
            <div>
              <h2 className="text-[30px] font-bold tracking-tight text-white">Create your account</h2>
              <p className="mt-1.5 text-[15px] text-white/55">
                Start your free trial. <span className="lg:hidden">30 days, no credit card.</span>
              </p>
            </div>

            <OAuthButtons mode="signup" dark />

            <SignupForm />

            <p className="text-center text-sm text-white/60">
              Already have an account?{" "}
              <Link href="/login" className="font-medium text-[#39a0ff] hover:text-[#75bdff] hover:underline">
                Sign in
              </Link>
            </p>
          </div>
        </AuthCard>
      </div>
    </AuthShell>
  );
}
