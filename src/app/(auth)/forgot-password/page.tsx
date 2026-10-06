import { Lock } from "lucide-react";
import { AuthShell } from "@/components/auth/auth-shell";
import { AuthCard } from "@/components/auth/auth-card";
import { ForgotPasswordForm } from "./forgot-password-form";

export default function ForgotPasswordPage() {
  return (
    <AuthShell centered>
      <AuthCard dark>
        <div className="space-y-5 text-center">
          <div className="mx-auto flex size-14 items-center justify-center rounded-full border border-[#2680ff]/35 bg-[#2680ff]/10 text-[#39a0ff]">
            <Lock className="size-6" />
          </div>
          <div>
            <h1 className="text-2xl font-bold tracking-tight text-white">Reset Your Password</h1>
            <p className="mt-1 text-sm text-white/60">Enter your email and we&apos;ll send instructions to reset your password.</p>
          </div>

          <ForgotPasswordForm />
        </div>
      </AuthCard>
    </AuthShell>
  );
}
