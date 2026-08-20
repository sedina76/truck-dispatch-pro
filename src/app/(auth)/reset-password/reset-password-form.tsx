"use client";

import { useActionState, useState } from "react";
import Link from "next/link";
import { Check } from "lucide-react";
import { updatePassword, type UpdatePasswordState } from "@/lib/supabase/actions";
import { PasswordField } from "@/components/auth/password-field";
import { AuthButton } from "@/components/auth/auth-button";

const initialState: UpdatePasswordState = { error: null };

export function ResetPasswordForm() {
  const [state, formAction, pending] = useActionState(updatePassword, initialState);
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");

  return (
    <form action={formAction} className="space-y-4 text-left" aria-busy={pending}>
      <PasswordField id="password" name="password" label="New Password" autoComplete="new-password" value={password} onChange={setPassword} disabled={pending} strength />

      <PasswordField id="confirmPassword" name="confirmPassword" label="Confirm New Password" autoComplete="new-password" value={confirmPassword} onChange={setConfirmPassword} disabled={pending} />

      {state.error && (
        <p role="alert" aria-live="polite" className="text-sm text-danger">
          {state.error}
        </p>
      )}

      <AuthButton type="submit" disabled={pending}>
        {pending ? (
          "Updating…"
        ) : (
          <>
            <Check className="size-4" />
            Update Password
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
  );
}
