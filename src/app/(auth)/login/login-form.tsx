"use client";

import { useActionState, useState } from "react";
import Link from "next/link";
import { LogIn } from "lucide-react";
import { login, type ActionState } from "@/lib/supabase/actions";
import { AuthInput } from "@/components/auth/auth-input";
import { PasswordField } from "@/components/auth/password-field";
import { AuthButton } from "@/components/auth/auth-button";

const initialState: ActionState = { error: null };

export function LoginForm() {
  const [state, formAction, pending] = useActionState(login, initialState);
  const [password, setPassword] = useState("");

  return (
    <form action={formAction} className="space-y-5" aria-busy={pending}>
      <div className="space-y-1.5">
        <label htmlFor="email" className="text-sm font-medium text-white/90">
          Email
        </label>
        <AuthInput dark id="email" name="email" type="email" autoComplete="email" placeholder="you@company.com" required disabled={pending} />
      </div>

      <PasswordField dark id="password" name="password" label="Password" autoComplete="current-password" value={password} onChange={setPassword} disabled={pending} />

      {/* "Remember me" is presentational-honest, not functional: Supabase's
          session already persists via a long-lived refresh-token cookie
          regardless of this checkbox. */}
      <div className="flex items-start justify-between gap-5">
        <label className="flex shrink-0 items-center gap-2 text-sm text-white/70">
          <input type="checkbox" name="rememberMe" className="size-4 rounded border-white/25 bg-white/5 text-[#2680ff] focus-visible:ring-2 focus-visible:ring-[#2680ff]/30" />
          Remember me
        </label>
        <div className="space-y-1 text-right text-sm">
          <Link href="/forgot-password" className="block font-medium text-[#39a0ff] hover:text-[#75bdff] hover:underline">
            Forgot password?
          </Link>
          <Link href="/forgot-email" className="block text-xs text-white/45 hover:text-white/70 hover:underline">
            Forgot email?
          </Link>
        </div>
      </div>

      {state.error && (
        <p role="alert" aria-live="polite" className="rounded-lg border border-red-400/25 bg-red-400/10 px-3 py-2 text-sm text-red-300">
          {state.error}
        </p>
      )}

      <AuthButton type="submit" disabled={pending}>
        {pending ? (
          "Signing in…"
        ) : (
          <>
            <LogIn className="size-4" />
            Sign In
          </>
        )}
      </AuthButton>
    </form>
  );
}
