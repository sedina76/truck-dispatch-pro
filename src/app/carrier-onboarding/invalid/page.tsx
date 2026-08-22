import { ShieldAlert } from "lucide-react";

// Deliberately generic (spec section 10/24) -- reached for a not-found,
// expired, AND revoked token/session alike, with no distinguishing detail
// and no reference to which organization or application might be behind
// it. A probing request learns nothing.
export default function InvalidCarrierOnboardingLinkPage() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-desktop-bg px-4">
      <div className="w-full max-w-sm rounded-md border border-desktop-border bg-card p-6 text-center shadow-elevation-1">
        <ShieldAlert className="mx-auto size-8 text-muted-foreground" />
        <h1 className="mt-3 text-base font-semibold text-desktop-text">This invitation link is no longer valid</h1>
        <p className="mt-2 text-sm text-muted-foreground">
          It may have expired or already been used. Please contact the dispatch office that invited you for a new link.
        </p>
      </div>
    </div>
  );
}
