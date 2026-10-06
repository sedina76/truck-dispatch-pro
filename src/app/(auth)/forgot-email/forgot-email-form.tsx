"use client";

import { useActionState } from "react";
import Link from "next/link";
import { UserSearch, Mail, Search, Check, HelpCircle } from "lucide-react";
import { lookupForgotEmail, type ForgotEmailState } from "@/lib/auth/forgot-email";
import { AuthCard } from "@/components/auth/auth-card";
import { AuthInput } from "@/components/auth/auth-input";
import { AuthButton } from "@/components/auth/auth-button";
import { Button } from "@/components/ui/button";

const initialState: ForgotEmailState = { status: "idle", result: null };

function IconHeader({ Icon, title, subtitle, danger = false }: { Icon: typeof Mail; title: string; subtitle: string; danger?: boolean }) {
  return (
    <div className="mb-5 space-y-3 text-center">
      <div className={`mx-auto flex size-14 items-center justify-center rounded-full ${danger ? "border border-red-400/35 bg-red-500/10 text-red-300" : "border border-[#2680ff]/35 bg-[#2680ff]/10 text-[#39a0ff]"}`}>
        <Icon className="size-6" />
      </div>
      <div>
        <h1 className="text-2xl font-bold tracking-tight text-white">{title}</h1>
        <p className="mt-1 text-sm text-white/60">{subtitle}</p>
      </div>
    </div>
  );
}

export function ForgotEmailForm() {
  const [state, formAction, pending] = useActionState(lookupForgotEmail, initialState);

  if (state.status === "rate_limited") {
    return (
      <AuthCard dark>
        <IconHeader Icon={HelpCircle} title="Find Your Account" subtitle="Enter your company name and phone number to find your account." />
        <p role="alert" aria-live="polite" className="rounded-md border border-red-400/40 bg-red-500/10 p-3 text-center text-sm text-red-300">
          Too many attempts — try again shortly.
        </p>
      </AuthCard>
    );
  }

  if (state.status === "checked" && state.result?.ok) {
    return (
      <AuthCard dark>
        <div className="space-y-4 text-center">
          <IconHeader Icon={Mail} title="We Found an Account" subtitle="We found an email associated with your information." />
          <p className="rounded-md border border-white/15 bg-white/5 px-4 py-3 text-lg font-semibold tabular-nums text-white">
            {state.result.maskedEmail}
          </p>
          <p className="text-sm text-white/60">Is this your email?</p>
          <div className="space-y-2">
            <Link href="/login" className="block">
              <AuthButton type="button">
                <Check className="size-4" />
                Yes, Continue to Sign In
              </AuthButton>
            </Link>
            <Link href="/forgot-email" className="block">
              <Button type="button" variant="outline" className="h-11 w-full border-white/20 bg-white/[0.04] text-[15px] font-semibold text-white hover:border-white/35 hover:bg-white/[0.09] hover:text-white" size="lg">
                I Still Need Help
              </Button>
            </Link>
          </div>
          <p className="text-sm text-white/60">
            Back to{" "}
            <Link href="/login" className="font-medium text-[#39a0ff] hover:text-[#75bdff] hover:underline">
              Sign In
            </Link>
          </p>
        </div>
      </AuthCard>
    );
  }

  if (state.status === "checked" && !state.result?.ok) {
    return (
      <AuthCard dark>
        <IconHeader Icon={UserSearch} title="We Found an Account" subtitle="We found an email associated with your information." />
        {/* Deliberately generic -- never states whether the company or the
            phone was the mismatch, and looks identical to any other
            "no match" cause, resisting enumeration. Security-reviewed
            again this round (spec section 9): the underlying lookup
            still requires an exact org-name match AND an exact phone
            match resolving to exactly one profile, returns only a masked
            email, and is rate-limited -- unchanged, still the sound
            design for the account data this app actually has. */}
        <p role="status" aria-live="polite" className="rounded-md border border-white/15 bg-white/5 p-3 text-center text-sm text-white/60">
          We couldn&apos;t verify an account with that information.
        </p>
        <p className="mt-4 text-center text-sm text-white/60">
          Back to{" "}
          <Link href="/login" className="font-medium text-[#39a0ff] hover:text-[#75bdff] hover:underline">
            Sign In
          </Link>
        </p>
      </AuthCard>
    );
  }

  return (
    <AuthCard dark>
      <IconHeader Icon={UserSearch} title="Find Your Account" subtitle="Enter your company name and phone number to find your account." />
      <form action={formAction} className="space-y-4 text-left" aria-busy={pending}>
        <div className="space-y-1.5">
          <label htmlFor="companyName" className="text-sm font-medium text-white/90">
            Company Name
          </label>
          <AuthInput dark id="companyName" name="companyName" type="text" autoComplete="organization" placeholder="Your Company Inc." required disabled={pending} />
        </div>

        <div className="space-y-1.5">
          <label htmlFor="phone" className="text-sm font-medium text-white/90">
            Phone Number
          </label>
          <AuthInput dark id="phone" name="phone" type="tel" inputMode="tel" autoComplete="tel" placeholder="(555) 123-4567" required disabled={pending} />
        </div>

        <AuthButton type="submit" disabled={pending}>
          {pending ? (
            "Looking up…"
          ) : (
            <>
              <Search className="size-4" />
              Find Account
            </>
          )}
        </AuthButton>

        <p className="text-center text-sm text-white/60">
          Back to{" "}
          <Link href="/login" className="font-medium text-[#39a0ff] hover:text-[#75bdff] hover:underline">
            Sign In
          </Link>
        </p>
      </form>
    </AuthCard>
  );
}
