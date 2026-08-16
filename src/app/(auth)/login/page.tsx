import Link from "next/link";
import { LoginForm } from "./login-form";

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ confirmEmail?: string }>;
}) {
  const { confirmEmail } = await searchParams;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-xl font-semibold">Sign in</h1>
        <p className="mt-1 text-sm text-[var(--color-text-muted)]">
          Dispatch, billing, and compliance in one place.
        </p>
      </div>

      {confirmEmail && (
        <p className="rounded-md border border-[var(--color-border)] bg-[var(--color-bg)] p-3 text-sm">
          Check your email to confirm your account before signing in.
        </p>
      )}

      <LoginForm />

      <p className="text-center text-sm text-[var(--color-text-muted)]">
        No account?{" "}
        <Link href="/signup" className="font-medium text-[var(--color-brand)]">
          Create one
        </Link>
      </p>

      <div className="space-y-2 border-t border-[var(--color-border)] pt-4 text-center text-sm text-[var(--color-text-muted)]">
        <p>Driver?</p>
        <div className="flex flex-col items-center gap-2 sm:flex-row sm:justify-center sm:gap-4">
          <Link
            href="/driver-application"
            className="font-medium text-[var(--color-brand)] underline-offset-2 hover:underline"
          >
            Apply for Employment
          </Link>
          <span className="hidden text-[var(--color-border)] sm:inline">|</span>
          <Link
            href="/driver-portal/login"
            className="font-medium text-[var(--color-brand)] underline-offset-2 hover:underline"
          >
            Driver Sign In
          </Link>
        </div>
      </div>
    </div>
  );
}
