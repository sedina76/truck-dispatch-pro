import { redirect } from "next/navigation";
import { getDriverOnboardingSession } from "@/lib/driver-onboarding/session";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { DriverOnboardingStepper } from "@/components/driver-onboarding/stepper";

// Phase 2Q.2 -- the ONE gate every driver onboarding step page sits
// behind. Mirrors src/app/carrier-onboarding/(portal)/layout.tsx exactly:
// a route group ((portal), not part of the URL) so /driver-onboarding/
// invalid itself stays completely ungated -- this is exactly where a
// request with no session, an expired session, or a session belonging to
// a cancelled/already-decided application lands, always via the same
// generic redirect (no distinguishable error).
export default async function DriverOnboardingPortalLayout({ children }: { children: React.ReactNode }) {
  const identity = await getDriverOnboardingSession();
  if (!identity) redirect("/driver-onboarding/invalid");

  const service = createServiceRoleClient();
  const { data: org } = await service.from("organizations").select("name").eq("id", identity.organizationId).maybeSingle();

  return (
    <div className="min-h-screen bg-desktop-bg">
      <header className="border-b border-desktop-border bg-card px-4 py-3 sm:px-6">
        <div className="mx-auto max-w-2xl">
          <p className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">Driver Onboarding</p>
          <h1 className="mt-0.5 text-lg font-semibold tracking-tight text-desktop-text">
            {org?.name ? `Join ${org.name}` : "Complete your driver onboarding"}
          </h1>
        </div>
      </header>
      <div className="mx-auto max-w-2xl px-4 py-5 sm:px-6">
        <DriverOnboardingStepper />
        <main className="mt-4">{children}</main>
      </div>
    </div>
  );
}
