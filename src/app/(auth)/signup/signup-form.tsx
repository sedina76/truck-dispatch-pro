"use client";

import { useActionState, useState } from "react";
import { UserPlus } from "lucide-react";
import { signup, type ActionState } from "@/lib/supabase/actions";
import { AuthInput } from "@/components/auth/auth-input";
import { PasswordField } from "@/components/auth/password-field";
import { AuthButton } from "@/components/auth/auth-button";

const initialState: ActionState = { error: null };

// Fields exactly as specified: Work Email, Password, Confirm Password --
// no separate full-name field. handle_new_user() (0009) already falls
// back to the email address for full_name when none is supplied via
// signup metadata, so this doesn't leave the profile row in a broken
// state -- the person can set their display name later from Settings ->
// Profile. Underlying supabase.auth.signUp() call is unchanged from the
// prior round -- this is a visual pass only.
export function SignupForm() {
  const [state, formAction, pending] = useActionState(signup, initialState);
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");

  return (
    <form action={formAction} className="space-y-4" aria-busy={pending}>
      <div className="space-y-1.5">
        <label htmlFor="email" className="text-sm font-medium text-[#3a3a34]">
          Work Email
        </label>
        <AuthInput id="email" name="email" type="email" autoComplete="email" placeholder="you@company.com" required disabled={pending} />
      </div>

      <PasswordField id="password" name="password" label="Password" autoComplete="new-password" value={password} onChange={setPassword} disabled={pending} strength />

      <PasswordField id="confirmPassword" name="confirmPassword" label="Confirm Password" autoComplete="new-password" value={confirmPassword} onChange={setConfirmPassword} disabled={pending} />

      {state.error && (
        <p role="alert" aria-live="polite" className="text-sm text-danger">
          {state.error}
        </p>
      )}

      <AuthButton type="submit" disabled={pending}>
        {pending ? (
          "Creating account…"
        ) : (
          <>
            <UserPlus className="size-4" />
            Create Account
          </>
        )}
      </AuthButton>
    </form>
  );
}
