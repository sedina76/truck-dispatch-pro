import "server-only";
import { randomBytes, createHash } from "node:crypto";
import { cookies } from "next/headers";
import { createServiceRoleClient } from "@/lib/supabase/service-role";

// ---------------------------------------------------------------------------
// Phase 2Q.2 -- the driver-onboarding-portal session. Mirrors
// src/lib/carrier-onboarding/session.ts exactly (randomBytes(32) raw
// token, sha256 hash at rest, httpOnly cookie, bootstrapped exactly once
// from a raw invitation token at GET /driver-onboarding/[token]). This is
// intentionally NOT the same thing as src/lib/driver-portal/session.ts --
// that is the phone+PIN session a driver gets AFTER hire/conversion for
// ongoing Driver Portal use; this is the one-time onboarding-application
// session before a real drivers row even exists.
// NOT YET LIVE: depends on migration 0108, not applied.
// ---------------------------------------------------------------------------

const COOKIE_NAME = "driver_onboarding_session";

export type DriverOnboardingIdentity = {
  sessionId: string;
  applicationId: string;
  organizationId: string;
};

export class DriverOnboardingSessionUnavailableError extends Error {
  constructor() {
    super("Your onboarding session has ended. Please use your invitation link again.");
    this.name = "DriverOnboardingSessionUnavailableError";
  }
}

function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

// Called ONLY from the [token] route handler, after that raw invitation
// token has already been validated. The session's own expires_at is
// capped at the invitation's own expires_at (never later).
export async function createDriverOnboardingSession(params: {
  applicationId: string;
  organizationId: string;
  invitationId: string;
  expiresAt: Date;
  userAgent: string | null;
}): Promise<void> {
  const token = randomBytes(32).toString("hex");
  const tokenHash = hashToken(token);

  const supabase = createServiceRoleClient();
  const { error } = await supabase.from("driver_onboarding_sessions").insert({
    application_id: params.applicationId,
    organization_id: params.organizationId,
    invitation_id: params.invitationId,
    token_hash: tokenHash,
    expires_at: params.expiresAt.toISOString(),
    user_agent: params.userAgent,
  });
  if (error) throw new Error(error.message);

  const cookieStore = await cookies();
  cookieStore.set(COOKIE_NAME, token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    expires: params.expiresAt,
  });
}

// Reads the session cookie and validates it against
// driver_onboarding_sessions -- returns null for no cookie, unknown/
// expired/revoked session, or a session whose parent application is
// somehow gone. Callers must treat null as "not in an active onboarding
// session" and route to the generic invalid-invitation page, never a more
// specific error.
export async function getDriverOnboardingSession(): Promise<DriverOnboardingIdentity | null> {
  const cookieStore = await cookies();
  const token = cookieStore.get(COOKIE_NAME)?.value;
  if (!token) return null;

  const supabase = createServiceRoleClient();
  const { data: session, error } = await supabase
    .from("driver_onboarding_sessions")
    .select("id, application_id, organization_id, expires_at, revoked_at")
    .eq("token_hash", hashToken(token))
    .maybeSingle();

  if (error) throw new Error(`Could not validate driver onboarding session: ${error.message}`);
  if (!session) return null;
  if (session.revoked_at) return null;
  if (new Date(session.expires_at) < new Date()) return null;

  return { sessionId: session.id, applicationId: session.application_id, organizationId: session.organization_id };
}

// requireDriverOnboardingSession() -- the one entry point every driver
// onboarding server action must call first, mirroring
// requireCarrierOnboardingSession()'s own convention exactly.
export async function requireDriverOnboardingSession(): Promise<DriverOnboardingIdentity> {
  const identity = await getDriverOnboardingSession();
  if (!identity) throw new DriverOnboardingSessionUnavailableError();
  return identity;
}
