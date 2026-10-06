"use client";

import { useActionState } from "react";
import Link from "next/link";
import { Send } from "lucide-react";
import { requestPasswordReset, type RequestResetState } from "@/lib/supabase/actions";
import { AuthInput } from "@/components/auth/auth-input";
import { AuthButton } from "@/components/auth/auth-button";

const initialState: RequestResetState = { error: null, sent: false };

export function ForgotPasswordForm() {
  const [state, formAction, pending] = useActionState(requestPasswordReset, initialState);

  if (state.sent) {
    return (
      <div className="space-y-4">
        <p role="status" aria-live="polite" className="rounded-md border border-emerald-400/30 bg-emerald-500/10 p-3 text-sm text-emerald-200">
          If an account exists for that email, we&apos;ve sent a Truck Dispatch Pro password-reset link. Check your inbox.
        </p>
        <p className="text-center text-sm text-white/60">
          Back to{" "}
          <Link href="/login" className="font-medium text-[#39a0ff] hover:text-[#75bdff] hover:underline">
            Sign In
          </Link>
        </p>
      </div>
    );
  }

  return (
    <form action={formAction} className="space-y-4 text-left" aria-busy={pending}>
      <div className="space-y-1.5">
        <label htmlFor="email" className="text-sm font-medium text-white/90">
          Email
        </label>
        <AuthInput dark id="email" name="email" type="email" autoComplete="email" placeholder="you@company.com" required disabled={pending} />
      </div>

      {state.error && (
        <p role="alert" aria-live="polite" className="text-sm text-red-300">
          {state.error}
        </p>
      )}

      <AuthButton type="submit" disabled={pending}>
        {pending ? (
          "Sending…"
        ) : (
          <>
            <Send className="size-4" />
            Send Reset Link
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
  );
}
