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
    <form action={formAction} className="space-y-4" aria-busy={pending}>
      <div className="space-y-1.5">
        <label htmlFor="email" className="text-sm font-medium text-[#3a3a34]">
          Email
        </label>
        <AuthInput id="email" name="email" type="email" autoComplete="email" placeholder="you@company.com" required disabled={pending} />
      </div>

      <PasswordField id="password" name="password" label="Password" autoComplete="current-password" value={password} onChange={setPassword} disabled={pending} />

      {/* "Remember me" is presentational-honest, not functional: Supabase's
          session already persists via a long-lived refresh-token cookie
          regardless of this checkbox. */}
      <div className="flex items-start justify-between">
        <label className="flex items-center gap-1.5 text-sm text-[#6b6b64]">
          <input type="checkbox" name="rememberMe" className="size-3.5 rounded border-[#d8d8d2] text-[#1c54b8] focus-visible:ring-2 focus-visible:ring-[#1c54b8]/20" />
          Remember me
        </label>
        <div className="space-y-1 text-right text-sm">
          <Link href="/forgot-password" className="block font-medium text-[#1c54b8] hover:underline">
            Forgot password?
          </Link>
          <Link href="/forgot-email" className="block text-xs text-[#9a9a92] hover:underline">
            Forgot email?
          </Link>
        </div>
      </div>

      {state.error && (
        <p role="alert" aria-live="polite" className="text-sm text-danger">
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
