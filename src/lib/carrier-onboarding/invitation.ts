import "server-only";
import { randomBytes, createHash } from "node:crypto";
import { createServiceRoleClient } from "@/lib/supabase/service-role";

// Phase 2L.4 -- staff-side invitation issuance, reused by both "Invite
// Carrier" (first invitation) and "Resend Invitation" (a fresh token, old
// invitation row left alone -- see onboarding/actions.ts). Same
// randomBytes(32)/sha256 mechanism as every other secure-token flow in
// this app (driver_portal_sessions, carrier_onboarding_sessions).

export const INVITATION_TTL_DAYS = 14;

export function invitationExpiresAt(): Date {
  return new Date(Date.now() + INVITATION_TTL_DAYS * 24 * 60 * 60 * 1000);
}

export async function issueCarrierOnboardingInvitation(params: {
  applicationId: string;
  organizationId: string;
  createdBy: string;
}): Promise<{ invitationId: string; url: string; expiresAt: Date }> {
  const token = randomBytes(32).toString("hex");
  const tokenHash = createHash("sha256").update(token).digest("hex");
  const expiresAt = invitationExpiresAt();

  const supabase = createServiceRoleClient();
  const { data, error } = await supabase
    .from("carrier_onboarding_invitations")
    .insert({
      organization_id: params.organizationId,
      application_id: params.applicationId,
      token_hash: tokenHash,
      expires_at: expiresAt.toISOString(),
      created_by: params.createdBy,
    })
    .select("id")
    .single();
  if (error) throw new Error(error.message);

  // Matches src/lib/supabase/actions.ts's own NEXT_PUBLIC_SITE_URL
  // convention exactly -- not a second env var for the same concept.
  const baseUrl = process.env.NEXT_PUBLIC_SITE_URL || "http://localhost:3000";
  const url = `${baseUrl.replace(/\/$/, "")}/carrier-onboarding/${token}`;

  return { invitationId: data.id, url, expiresAt };
}
