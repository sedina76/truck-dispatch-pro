import { redirect } from "next/navigation";
import { Mail } from "lucide-react";
import { AuthShell } from "@/components/auth/auth-shell";
import { AuthCard } from "@/components/auth/auth-card";
import { VerifyEmailForm } from "./verify-email-form";

export default async function VerifyEmailPage({ searchParams }: { searchParams: Promise<{ email?: string }> }) {
  const { email } = await searchParams;
  if (!email) redirect("/signup");

  return (
    <AuthShell centered>
      <AuthCard>
        <div className="space-y-5 text-center">
          <div className="mx-auto flex size-14 items-center justify-center rounded-full bg-[#1c54b8]/10 text-[#1c54b8]">
            <Mail className="size-6" />
          </div>
          <div>
            <h1 className="text-2xl font-bold tracking-tight text-[#1a1a18]">Verify Your Email</h1>
            <p className="mt-2 text-sm text-[#6b6b64]">
              We sent a verification code to
              <br />
              <span className="font-semibold text-[#1a1a18]">{email}</span>
            </p>
          </div>

          <VerifyEmailForm email={email} />
        </div>
      </AuthCard>
    </AuthShell>
  );
}
