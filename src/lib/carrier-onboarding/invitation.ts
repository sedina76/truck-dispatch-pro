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

// Pilot readiness audit P1-1 hardening: a prior pass only logged a
// production warning when NEXT_PUBLIC_SITE_URL was unset and still fell
// back to http://localhost:3000 -- an invitation could still go out with a
// link no outside carrier could ever open. This now requires a real,
// well-formed, non-localhost URL in production; development keeps the
// plain localhost fallback untouched (no env var needed for `npm run dev`).
// No shared helper for this exists anywhere in the codebase today (checked
// before writing this) -- duplicated identically in
// src/lib/driver-onboarding/invitation.ts, the one other place with the
// exact same NEXT_PUBLIC_SITE_URL convention, rather than introducing a
// new shared module for a single-call-site check in each file.
function isUsableProductionSiteUrl(value: string): boolean {
  if (!value.trim()) return false;
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return false;
  }
  const host = parsed.hostname.toLowerCase();
  return host !== "localhost" && host !== "127.0.0.1" && host !== "::1" && !host.startsWith("127.");
}

export async function issueCarrierOnboardingInvitation(params: {
  applicationId: string;
  organizationId: string;
  createdBy: string;
}): Promise<{ invitationId: string; url: string; expiresAt: Date }> {
  // Fail before generating a token or writing any row: a bad
  // NEXT_PUBLIC_SITE_URL in production means no usable link can ever be
  // produced for this call, so there is nothing safe to persist yet.
  const rawSiteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? "";
  if (process.env.NODE_ENV === "production" && !isUsableProductionSiteUrl(rawSiteUrl)) {
    throw new Error(
      "Could not create a carrier onboarding invitation: NEXT_PUBLIC_SITE_URL is missing, malformed, or points at localhost. Set it to the real deployed site URL before inviting a carrier."
    );
  }

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
  // convention -- production correctness is already guaranteed by the
  // validated-and-thrown check above, so this fallback can only ever be
  // reached in development.
  const baseUrl = rawSiteUrl || "http://localhost:3000";
  const url = `${baseUrl.replace(/\/$/, "")}/carrier-onboarding/${token}`;

  return { invitationId: data.id, url, expiresAt };
}
