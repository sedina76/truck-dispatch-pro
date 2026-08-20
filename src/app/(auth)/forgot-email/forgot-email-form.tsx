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
      <div className={`mx-auto flex size-14 items-center justify-center rounded-full ${danger ? "bg-danger/10 text-danger" : "bg-[#1c54b8]/10 text-[#1c54b8]"}`}>
        <Icon className="size-6" />
      </div>
      <div>
        <h1 className="text-2xl font-bold tracking-tight text-[#1a1a18]">{title}</h1>
        <p className="mt-1 text-sm text-[#6b6b64]">{subtitle}</p>
      </div>
    </div>
  );
}

export function ForgotEmailForm() {
  const [state, formAction, pending] = useActionState(lookupForgotEmail, initialState);

  if (state.status === "rate_limited") {
    return (
      <AuthCard>
        <IconHeader Icon={HelpCircle} title="Find Your Account" subtitle="Enter your company name and phone number to find your account." />
        <p role="alert" aria-live="polite" className="rounded-md border border-danger/30 bg-danger/10 p-3 text-center text-sm text-danger">
          Too many attempts — try again shortly.
        </p>
      </AuthCard>
    );
  }

  if (state.status === "checked" && state.result?.ok) {
    return (
      <AuthCard>
        <div className="space-y-4 text-center">
          <IconHeader Icon={Mail} title="We Found an Account" subtitle="We found an email associated with your information." />
          <p className="rounded-md border border-[#e4e4e0] bg-white px-4 py-3 text-lg font-semibold tabular-nums text-[#1a1a18]">
            {state.result.maskedEmail}
          </p>
          <p className="text-sm text-[#6b6b64]">Is this your email?</p>
          <div className="space-y-2">
            <Link href="/login" className="block">
              <AuthButton type="button">
                <Check className="size-4" />
                Yes, Continue to Sign In
              </AuthButton>
            </Link>
            <Link href="/forgot-email" className="block">
              <Button type="button" variant="outline" className="h-11 w-full border-[#d8d8d2] bg-white text-[15px] font-semibold text-[#3a3a34] hover:bg-[#f5f4f1]" size="lg">
                I Still Need Help
              </Button>
            </Link>
          </div>
          <p className="text-sm text-[#6b6b64]">
            Back to{" "}
            <Link href="/login" className="font-medium text-[#1c54b8] hover:underline">
              Sign In
            </Link>
          </p>
        </div>
      </AuthCard>
    );
  }

  if (state.status === "checked" && !state.result?.ok) {
    return (
      <AuthCard>
        <IconHeader Icon={UserSearch} title="We Found an Account" subtitle="We found an email associated with your information." />
        {/* Deliberately generic -- never states whether the company or the
            phone was the mismatch, and looks identical to any other
            "no match" cause, resisting enumeration. Security-reviewed
            again this round (spec section 9): the underlying lookup
            still requires an exact org-name match AND an exact phone
            match resolving to exactly one profile, returns only a masked
            email, and is rate-limited -- unchanged, still the sound
            design for the account data this app actually has. */}
        <p role="status" aria-live="polite" className="rounded-md border border-[#e4e4e0] bg-white p-3 text-center text-sm text-[#6b6b64]">
          We couldn&apos;t verify an account with that information.
        </p>
        <p className="mt-4 text-center text-sm text-[#6b6b64]">
          Back to{" "}
          <Link href="/login" className="font-medium text-[#1c54b8] hover:underline">
            Sign In
          </Link>
        </p>
      </AuthCard>
    );
  }

  return (
    <AuthCard>
      <IconHeader Icon={UserSearch} title="Find Your Account" subtitle="Enter your company name and phone number to find your account." />
      <form action={formAction} className="space-y-4 text-left" aria-busy={pending}>
        <div className="space-y-1.5">
          <label htmlFor="companyName" className="text-sm font-medium text-[#3a3a34]">
            Company Name
          </label>
          <AuthInput id="companyName" name="companyName" type="text" autoComplete="organization" placeholder="Your Company Inc." required disabled={pending} />
        </div>

        <div className="space-y-1.5">
          <label htmlFor="phone" className="text-sm font-medium text-[#3a3a34]">
            Phone Number
          </label>
          <AuthInput id="phone" name="phone" type="tel" inputMode="tel" autoComplete="tel" placeholder="(555) 123-4567" required disabled={pending} />
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

        <p className="text-center text-sm text-[#6b6b64]">
          Back to{" "}
          <Link href="/login" className="font-medium text-[#1c54b8] hover:underline">
            Sign In
          </Link>
        </p>
      </form>
    </AuthCard>
  );
}
