import { NextRequest, NextResponse } from "next/server";
import { createHash } from "node:crypto";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { createCarrierOnboardingSession } from "@/lib/carrier-onboarding/session";

// Phase 2L.4 -- the ONE place the raw invitation token is ever read. A GET
// here (from the emailed link, or a staff-copied URL) validates the
// token, bootstraps an httpOnly session cookie scoped to exactly one
// application, and redirects into the step flow -- every subsequent
// request reads that cookie, never this URL's token again (see
// src/lib/carrier-onboarding/session.ts's own header comment).
//
// Security (spec section 10/24): token compared only by its sha256 hash
// (never a raw-string compare); on ANY failure (not found, expired,
// revoked) this returns the exact same generic redirect -- never a
// distinguishable error -- so a probing request learns nothing about
// which case occurred or whether any application/org exists behind a
// guessed token.
export async function GET(request: NextRequest, { params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const origin = request.nextUrl.origin;
  const invalidUrl = new URL("/carrier-onboarding/invalid", origin);

  if (!token || !/^[0-9a-f]{64}$/i.test(token)) {
    return NextResponse.redirect(invalidUrl);
  }

  const tokenHash = createHash("sha256").update(token).digest("hex");
  const supabase = createServiceRoleClient();

  const { data: invitation } = await supabase
    .from("carrier_onboarding_invitations")
    .select("id, organization_id, application_id, expires_at, revoked_at, first_viewed_at")
    .eq("token_hash", tokenHash)
    .maybeSingle();

  if (!invitation || invitation.revoked_at || new Date(invitation.expires_at) < new Date()) {
    return NextResponse.redirect(invalidUrl);
  }

  const now = new Date();
  await supabase
    .from("carrier_onboarding_invitations")
    .update({
      first_viewed_at: invitation.first_viewed_at ?? now.toISOString(),
      last_viewed_at: now.toISOString(),
    })
    .eq("id", invitation.id);

  await createCarrierOnboardingSession({
    applicationId: invitation.application_id,
    organizationId: invitation.organization_id,
    invitationId: invitation.id,
    expiresAt: new Date(invitation.expires_at),
    userAgent: request.headers.get("user-agent"),
  });

  // Best-effort activity log -- insert() resolves with {error} rather than
  // rejecting, so this never throws or blocks the redirect either way.
  await supabase.from("activity_logs").insert({
    organization_id: invitation.organization_id,
    entity_type: "carrier_onboarding_application",
    entity_id: invitation.application_id,
    action: "invitation_opened",
    actor_id: null,
    changes: {},
  });

  return NextResponse.redirect(new URL("/carrier-onboarding/welcome", origin));
}
