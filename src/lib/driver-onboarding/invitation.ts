import "server-only";
import { randomBytes, createHash } from "node:crypto";
import { createServiceRoleClient } from "@/lib/supabase/service-role";

// Phase 2Q.2 -- staff-side invitation issuance for carrier-assigned driver
// onboarding, reused by both "Invite Driver" (first invitation) and
// "Resend Invitation" (a fresh token, old invitation row left alone -- see
// drivers/applications/actions.ts). Same randomBytes(32)/sha256 mechanism,
// and the same 14-day TTL, as src/lib/carrier-onboarding/invitation.ts --
// deliberately not a third convention for the same concept.
// NOT YET LIVE: depends on migration 0108, not applied.

export const INVITATION_TTL_DAYS = 14;

export function invitationExpiresAt(): Date {
  return new Date(Date.now() + INVITATION_TTL_DAYS * 24 * 60 * 60 * 1000);
}

// Pilot readiness audit P1-1 hardening -- identical rationale and identical
// logic to src/lib/carrier-onboarding/invitation.ts's own copy of this
// function (see that file's header comment for why this is duplicated
// rather than centralized: no shared helper exists anywhere in the
// codebase today for this single-call-site check).
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

export async function issueDriverOnboardingInvitation(params: {
  applicationId: string;
  organizationId: string;
  createdBy: string;
}): Promise<{ invitationId: string; url: string; expiresAt: Date }> {
  // Fail before generating a token or writing any row -- see the identical
  // check in src/lib/carrier-onboarding/invitation.ts.
  const rawSiteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? "";
  if (process.env.NODE_ENV === "production" && !isUsableProductionSiteUrl(rawSiteUrl)) {
    throw new Error(
      "Could not create a driver onboarding invitation: NEXT_PUBLIC_SITE_URL is missing, malformed, or points at localhost. Set it to the real deployed site URL before inviting a driver."
    );
  }

  const token = randomBytes(32).toString("hex");
  const tokenHash = createHash("sha256").update(token).digest("hex");
  const expiresAt = invitationExpiresAt();

  const supabase = createServiceRoleClient();
  const { data, error } = await supabase
    .from("driver_onboarding_invitations")
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

  // Production correctness is already guaranteed by the validated-and-
  // thrown check above, so this fallback can only ever be reached in
  // development.
  const baseUrl = rawSiteUrl || "http://localhost:3000";
  const url = `${baseUrl.replace(/\/$/, "")}/driver-onboarding/${token}`;

  return { invitationId: data.id, url, expiresAt };
}
