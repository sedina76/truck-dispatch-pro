"use client";

import { useActionState, useEffect, useState } from "react";
import Link from "next/link";
import { Check } from "lucide-react";
import { verifySignupOtp, resendSignupOtp, type VerifyOtpState, type ResendOtpState } from "@/lib/supabase/actions";
import { OtpInput } from "@/components/ui/otp-input";
import { AuthButton } from "@/components/auth/auth-button";

const verifyInitial: VerifyOtpState = { error: null };
const resendInitial: ResendOtpState = { error: null, sent: false };
const RESEND_COOLDOWN_SECONDS = 30;

export function VerifyEmailForm({ email }: { email: string }) {
  const [otp, setOtp] = useState("");
  const [verifyState, verifyAction, verifyPending] = useActionState(verifySignupOtp, verifyInitial);
  const [resendState, resendAction, resendPending] = useActionState(resendSignupOtp, resendInitial);
  const [cooldown, setCooldown] = useState(0);

  useEffect(() => {
    if (resendState.sent) setCooldown(RESEND_COOLDOWN_SECONDS);
  }, [resendState.sent]);

  useEffect(() => {
    if (cooldown <= 0) return;
    const t = setInterval(() => setCooldown((c) => Math.max(0, c - 1)), 1000);
    return () => clearInterval(t);
  }, [cooldown]);

  const fmt = (s: number) => `${Math.floor(s / 60).toString().padStart(2, "0")}:${(s % 60).toString().padStart(2, "0")}`;

  return (
    <div className="space-y-5">
      <form action={verifyAction} className="space-y-5" aria-busy={verifyPending}>
        <input type="hidden" name="email" value={email} />
        <input type="hidden" name="token" value={otp} />

        <OtpInput value={otp} onChange={setOtp} disabled={verifyPending} autoFocus />

        {/* No "code expires in..." countdown here, deliberately: Supabase
            Auth's verifyOtp/resend responses carry no expires-at value for
            the signup confirmation code, and the real TTL is a
            dashboard-configured project setting this app cannot read.
            Showing a timer would mean fabricating a number. The cooldown
            below next to "Resend code" IS real -- it's this component's
            own 30s client-side throttle. */}

        {verifyState.error && (
          <p role="alert" aria-live="polite" className="text-center text-sm text-danger">
            {verifyState.error}
          </p>
        )}

        <AuthButton type="submit" disabled={verifyPending || otp.length !== 6}>
          {verifyPending ? (
            "Verifying…"
          ) : (
            <>
              <Check className="size-4" />
              Verify Email
            </>
          )}
        </AuthButton>
      </form>

      <div className="flex items-center justify-center gap-1 text-sm text-[#6b6b64]">
        <span>Didn&apos;t receive it?</span>
        <form action={resendAction}>
          <input type="hidden" name="email" value={email} />
          <button
            type="submit"
            disabled={resendPending || cooldown > 0}
            className="font-medium text-[#1c54b8] hover:underline disabled:cursor-not-allowed disabled:text-[#b0b0a8] disabled:no-underline"
          >
            {resendPending ? "Sending…" : cooldown > 0 ? `Resend code (${fmt(cooldown)})` : "Resend code"}
          </button>
        </form>
      </div>

      {resendState.sent && cooldown === RESEND_COOLDOWN_SECONDS && (
        <p role="status" aria-live="polite" className="text-center text-sm text-emerald-600">
          Code resent.
        </p>
      )}
      {resendState.error && (
        <p role="alert" aria-live="polite" className="text-center text-sm text-danger">
          {resendState.error}
        </p>
      )}

      <p className="text-center text-sm text-[#6b6b64]">
        Wrong email?{" "}
        <Link href="/signup" className="font-medium text-[#1c54b8] hover:underline">
          Change email
        </Link>
      </p>
    </div>
  );
}
