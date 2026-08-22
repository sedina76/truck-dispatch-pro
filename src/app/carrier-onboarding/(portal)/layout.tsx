import { redirect } from "next/navigation";
import { getCarrierOnboardingSession } from "@/lib/carrier-onboarding/session";
import { OnboardingStepper } from "@/components/carrier-onboarding/stepper";

// Phase 2L.4 -- the ONE gate every step page sits behind. A route group
// ((portal), not part of the URL) so /carrier-onboarding/invalid itself
// can stay completely ungated -- this is exactly where a request with no
// session, an expired session, or a session belonging to a converted/
// long-dead application lands, always via the same generic redirect (spec
// section 24: no distinguishable error).
export default async function CarrierOnboardingPortalLayout({ children }: { children: React.ReactNode }) {
  const identity = await getCarrierOnboardingSession();
  if (!identity) redirect("/carrier-onboarding/invalid");

  return (
    <div className="min-h-screen bg-desktop-bg">
      <header className="border-b border-desktop-border bg-card px-4 py-3 sm:px-6">
        <div className="mx-auto max-w-2xl">
          <p className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">Carrier Onboarding</p>
          <h1 className="mt-0.5 text-lg font-semibold tracking-tight text-desktop-text">Complete your carrier profile and dispatch agreement</h1>
        </div>
      </header>
      <div className="mx-auto max-w-2xl px-4 py-5 sm:px-6">
        <OnboardingStepper />
        <main className="mt-4">{children}</main>
      </div>
    </div>
  );
}
