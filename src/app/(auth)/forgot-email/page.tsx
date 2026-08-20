import { AuthShell } from "@/components/auth/auth-shell";
import { ForgotEmailForm } from "./forgot-email-form";

export default function ForgotEmailPage() {
  return (
    <AuthShell centered>
      <ForgotEmailForm />
    </AuthShell>
  );
}
