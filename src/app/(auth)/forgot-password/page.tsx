import { Lock } from "lucide-react";
import { AuthShell } from "@/components/auth/auth-shell";
import { AuthCard } from "@/components/auth/auth-card";
import { ForgotPasswordForm } from "./forgot-password-form";

export default function ForgotPasswordPage() {
  return (
    <AuthShell centered>
      <AuthCard>
        <div className="space-y-5 text-center">
          <div className="mx-auto flex size-14 items-center justify-center rounded-full bg-[#1c54b8]/10 text-[#1c54b8]">
            <Lock className="size-6" />
          </div>
          <div>
            <h1 className="text-2xl font-bold tracking-tight text-[#1a1a18]">Reset Your Password</h1>
            <p className="mt-1 text-sm text-[#6b6b64]">Enter your email and we&apos;ll send instructions to reset your password.</p>
          </div>

          <ForgotPasswordForm />
        </div>
      </AuthCard>
    </AuthShell>
  );
}
