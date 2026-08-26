import { NextRequest, NextResponse } from "next/server";
import { createHash } from "node:crypto";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { createDriverOnboardingSession } from "@/lib/driver-onboarding/session";

// Phase 2Q.2 -- the ONE place the raw driver-invitation token is ever
// read. Mirrors src/app/carrier-onboarding/[token]/route.ts exactly: a GET
// here (from the emailed link) validates the token, bootstraps an httpOnly
// session cookie scoped to exactly one application, flips a fresh
// invitation's application from 'invited' to 'in_progress' on first open,
// and redirects into the step flow -- every subsequent request reads that
// cookie, never this URL's token again.
// NOT YET LIVE: depends on migration 0108, not applied.
//
// Security: token compared only by its sha256 hash; on ANY failure (not
// found, expired, revoked) this returns the exact same generic redirect --
// never a distinguishable error -- so a probing request learns nothing
// about which case occurred or whether any application/org exists behind
// a guessed token.
export async function GET(request: NextRequest, { params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const origin = request.nextUrl.origin;
  const invalidUrl = new URL("/driver-onboarding/invalid", origin);

  if (!token || !/^[0-9a-f]{64}$/i.test(token)) {
    return NextResponse.redirect(invalidUrl);
  }

  const tokenHash = createHash("sha256").update(token).digest("hex");
  const supabase = createServiceRoleClient();

  const { data: invitation } = await supabase
    .from("driver_onboarding_invitations")
    .select("id, organization_id, application_id, expires_at, revoked_at, first_viewed_at")
    .eq("token_hash", tokenHash)
    .maybeSingle();

  if (!invitation || invitation.revoked_at || new Date(invitation.expires_at) < new Date()) {
    return NextResponse.redirect(invalidUrl);
  }

  const { data: application } = await supabase
    .from("driver_applications")
    .select("id, status")
    .eq("id", invitation.application_id)
    .maybeSingle();
  if (!application) return NextResponse.redirect(invalidUrl);
  // A cancelled/expired/already-submitted-and-decided application no
  // longer accepts new onboarding activity through this link -- same
  // generic redirect, no distinguishable reason given to the browser.
  if (!["invited", "in_progress", "needs_correction"].includes(application.status)) {
    return NextResponse.redirect(invalidUrl);
  }

  const now = new Date();
  await supabase
    .from("driver_onboarding_invitations")
    .update({
      first_viewed_at: invitation.first_viewed_at ?? now.toISOString(),
      last_viewed_at: now.toISOString(),
    })
    .eq("id", invitation.id);

  // First-open transition (spec Section D: Invited -> In Progress).
  // needs_correction is left alone here -- it only moves forward again
  // once the driver actually resubmits (see actions.ts).
  if (application.status === "invited") {
    await supabase.from("driver_applications").update({ status: "in_progress" }).eq("id", application.id);
  }

  await createDriverOnboardingSession({
    applicationId: invitation.application_id,
    organizationId: invitation.organization_id,
    invitationId: invitation.id,
    expiresAt: new Date(invitation.expires_at),
    userAgent: request.headers.get("user-agent"),
  });

  // Best-effort activity log -- never blocks the redirect either way.
  await supabase.from("activity_logs").insert({
    organization_id: invitation.organization_id,
    entity_type: "driver_application",
    entity_id: invitation.application_id,
    action: "invitation_opened",
    actor_id: null,
    changes: {},
  });

  return NextResponse.redirect(new URL("/driver-onboarding/welcome", origin));
}
