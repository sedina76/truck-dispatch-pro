import Link from "next/link";
import { Lock, AlertTriangle } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { AuthShell } from "@/components/auth/auth-shell";
import { AuthCard } from "@/components/auth/auth-card";
import { ResetPasswordForm } from "./reset-password-form";

export default async function ResetPasswordPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const { error } = await searchParams;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const linkInvalid = Boolean(error) || !user;

  if (linkInvalid) {
    return (
      <AuthShell centered>
        <AuthCard>
          <div className="space-y-5 text-center">
            <div className="mx-auto flex size-14 items-center justify-center rounded-full bg-danger/10 text-danger">
              <AlertTriangle className="size-6" />
            </div>
            <div>
              <h1 className="text-2xl font-bold tracking-tight text-[#1a1a18]">Link Expired</h1>
              <p className="mt-1 text-sm text-[#6b6b64]">
                This password reset link is invalid or has already been used. Request a new one to continue.
              </p>
            </div>
            <Link href="/forgot-password" className="inline-block text-sm font-medium text-[#1c54b8] hover:underline">
              Request a new link
            </Link>
            <p className="text-sm text-[#6b6b64]">
              Back to{" "}
              <Link href="/login" className="font-medium text-[#1c54b8] hover:underline">
                Sign In
              </Link>
            </p>
          </div>
        </AuthCard>
      </AuthShell>
    );
  }

  return (
    <AuthShell centered>
      <AuthCard>
        <div className="space-y-5 text-center">
          <div className="mx-auto flex size-14 items-center justify-center rounded-full bg-[#1c54b8]/10 text-[#1c54b8]">
            <Lock className="size-6" />
          </div>
          <div>
            <h1 className="text-2xl font-bold tracking-tight text-[#1a1a18]">Create New Password</h1>
            <p className="mt-1 text-sm text-[#6b6b64]">Enter your new password below.</p>
          </div>
          <ResetPasswordForm />
        </div>
      </AuthCard>
    </AuthShell>
  );
}
