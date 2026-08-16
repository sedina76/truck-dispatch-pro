import Link from "next/link";

// Deliberately makes zero network calls (no Supabase, no external fetch) --
// this is the one page the app must be able to render even when the
// database/auth backend is completely unreachable, so a backend outage shows
// a clear message instead of a raw fetch-failed stack trace.
export default function MaintenancePage() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-[var(--color-bg)] px-6">
      <div className="max-w-md text-center">
        <h1 className="text-xl font-semibold">We&apos;ll be right back</h1>
        <p className="mt-3 text-sm text-[var(--color-text-muted)]">
          Truck Dispatch can&apos;t reach its database right now. This is usually temporary --
          please try again in a few minutes.
        </p>
        <Link
          href="/"
          className="mt-6 inline-flex items-center gap-1.5 rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary-hover"
        >
          Try again
        </Link>
      </div>
    </div>
  );
}
