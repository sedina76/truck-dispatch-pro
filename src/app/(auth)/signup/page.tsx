import Link from "next/link";
import { SignupForm } from "./signup-form";

export default function SignupPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-xl font-semibold">Create your account</h1>
        <p className="mt-1 text-sm text-[var(--color-text-muted)]">
          You&apos;ll set up your dispatch company on the next step.
        </p>
      </div>

      <SignupForm />

      <p className="text-center text-sm text-[var(--color-text-muted)]">
        Already have an account?{" "}
        <Link href="/login" className="font-medium text-[var(--color-brand)]">
          Sign in
        </Link>
      </p>
    </div>
  );
}
