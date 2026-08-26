import { ShieldAlert } from "lucide-react";

// Mirrors src/app/carrier-onboarding/invalid/page.tsx exactly -- deliberately
// generic for a not-found, expired, revoked, or no-longer-open-status
// token/session alike. A probing request learns nothing.
export default function InvalidDriverOnboardingLinkPage() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-desktop-bg px-4">
      <div className="w-full max-w-sm rounded-md border border-desktop-border bg-card p-6 text-center shadow-elevation-1">
        <ShieldAlert className="mx-auto size-8 text-muted-foreground" />
        <h1 className="mt-3 text-base font-semibold text-desktop-text">This invitation link is no longer valid</h1>
        <p className="mt-2 text-sm text-muted-foreground">
          It may have expired, already been used, or already been reviewed. Please contact the company that invited you for a new link.
        </p>
      </div>
    </div>
  );
}
