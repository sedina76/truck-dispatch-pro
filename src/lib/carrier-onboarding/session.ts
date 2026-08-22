import "server-only";
import { randomBytes, createHash } from "node:crypto";
import { cookies } from "next/headers";
import { createServiceRoleClient } from "@/lib/supabase/service-role";

// ---------------------------------------------------------------------------
// Phase 2L.4 -- the carrier-portal session. Mirrors
// src/lib/driver-portal/session.ts exactly (randomBytes(32) raw token,
// sha256 hash at rest, httpOnly cookie) with one structural difference:
// driver-portal sessions are minted after a phone+PIN login; this session
// is bootstrapped exactly once from a raw invitation token consumed at
// GET /carrier-onboarding/[token] (see route.ts), and every subsequent
// portal request reads this cookie -- the raw invitation token is never
// read again after that one bootstrap request.
// ---------------------------------------------------------------------------

const COOKIE_NAME = "carrier_onboarding_session";

export type CarrierOnboardingIdentity = {
  sessionId: string;
  applicationId: string;
  organizationId: string;
};

export class CarrierOnboardingSessionUnavailableError extends Error {
  constructor() {
    super("Your onboarding session has ended. Please use your invitation link again.");
    this.name = "CarrierOnboardingSessionUnavailableError";
  }
}

function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

// Called ONLY from the [token] route handler, after that raw invitation
// token has already been validated. Mints a NEW session row/cookie -- the
// session's own expires_at is capped at the invitation's own expires_at
// (never later), so a session can never outlive the window staff actually
// intended to grant.
export async function createCarrierOnboardingSession(params: {
  applicationId: string;
  organizationId: string;
  invitationId: string;
  expiresAt: Date;
  userAgent: string | null;
}): Promise<void> {
  const token = randomBytes(32).toString("hex");
  const tokenHash = hashToken(token);

  const supabase = createServiceRoleClient();
  const { error } = await supabase.from("carrier_onboarding_sessions").insert({
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

// Reads the session cookie and validates it against carrier_onboarding_sessions
// -- returns null for no cookie, unknown/expired/revoked session, or a
// session whose parent application is somehow gone. Callers must treat
// null as "not in an active onboarding session" and route to the generic
// invalid-invitation page, never a more specific error.
export async function getCarrierOnboardingSession(): Promise<CarrierOnboardingIdentity | null> {
  const cookieStore = await cookies();
  const token = cookieStore.get(COOKIE_NAME)?.value;
  if (!token) return null;

  const supabase = createServiceRoleClient();
  const { data: session, error } = await supabase
    .from("carrier_onboarding_sessions")
    .select("id, application_id, organization_id, expires_at, revoked_at")
    .eq("token_hash", hashToken(token))
    .maybeSingle();

  if (error) throw new Error(`Could not validate carrier onboarding session: ${error.message}`);
  if (!session) return null;
  if (session.revoked_at) return null;
  if (new Date(session.expires_at) < new Date()) return null;

  return { sessionId: session.id, applicationId: session.application_id, organizationId: session.organization_id };
}

// requireCarrierOnboardingSession() -- the one entry point every
// carrier-portal server action must call first, mirroring driver-portal
// actions.ts's own requireIdentity() convention exactly.
export async function requireCarrierOnboardingSession(): Promise<CarrierOnboardingIdentity> {
  const identity = await getCarrierOnboardingSession();
  if (!identity) throw new CarrierOnboardingSessionUnavailableError();
  return identity;
}
