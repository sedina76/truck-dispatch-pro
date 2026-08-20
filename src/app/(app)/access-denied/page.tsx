import Link from "next/link";
import { ShieldAlert } from "lucide-react";

// Landed on by requireRole() (src/lib/auth/require-role.ts) when a signed-in
// user's role isn't permitted on the page they requested. Deliberately
// inside (app) -- it keeps the normal shell (sidebar/toolbar/status bar) so
// it doesn't look like a broken page, it looks like a real, expected screen
// of this application.
export default function AccessDeniedPage() {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-3 text-center">
      <div className="flex size-12 items-center justify-center rounded-full bg-danger/10 text-danger">
        <ShieldAlert className="size-6" />
      </div>
      <div>
        <p className="text-[15px] font-semibold text-desktop-text">You don&apos;t have access to this page</p>
        <p className="mt-1 max-w-sm text-[13px] text-muted-foreground">
          Your role doesn&apos;t include this area. If you believe this is a mistake, ask an owner or admin to review your role under Settings &rarr; Users &amp; Roles.
        </p>
      </div>
      <Link href="/dashboard" className="mt-2 inline-flex h-8 items-center rounded-sm bg-primary px-3 text-[13px] font-medium text-primary-foreground hover:bg-primary-hover">
        Back to Dashboard
      </Link>
    </div>
  );
}
