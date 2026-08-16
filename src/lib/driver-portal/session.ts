import "server-only";
import { randomBytes, createHash } from "node:crypto";
import { cookies } from "next/headers";
import { createServiceRoleClient } from "@/lib/supabase/service-role";

const COOKIE_NAME = "driver_portal_session";
const SESSION_TTL_HOURS = 24 * 14; // 2 weeks

export type DriverPortalIdentity = {
  driverId: string;
  organizationId: string;
  firstName: string;
  lastName: string;
};

function hashToken(token: string) {
  return createHash("sha256").update(token).digest("hex");
}

// Creates a new session row and sets the cookie. The raw token only ever
// exists in the browser cookie and in transit here -- the database stores
// only its sha256 hash, so a leaked DB row can't be replayed as a cookie.
export async function createDriverPortalSession(
  driverId: string,
  organizationId: string,
  userAgent: string | null
) {
  const token = randomBytes(32).toString("hex");
  const tokenHash = hashToken(token);
  const expiresAt = new Date(Date.now() + SESSION_TTL_HOURS * 60 * 60 * 1000);

  const supabase = createServiceRoleClient();
  const { error } = await supabase.from("driver_portal_sessions").insert({
    driver_id: driverId,
    organization_id: organizationId,
    token_hash: tokenHash,
    user_agent: userAgent,
    expires_at: expiresAt.toISOString(),
  });
  if (error) throw error;

  const cookieStore = await cookies();
  cookieStore.set(COOKIE_NAME, token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    expires: expiresAt,
  });
}

export async function clearDriverPortalSession() {
  const cookieStore = await cookies();
  const token = cookieStore.get(COOKIE_NAME)?.value;
  if (token) {
    const supabase = createServiceRoleClient();
    await supabase.from("driver_portal_sessions").delete().eq("token_hash", hashToken(token));
  }
  cookieStore.delete(COOKIE_NAME);
}

// Reads the session cookie and validates it against driver_portal_sessions.
// Returns null if there's no cookie, the session doesn't exist, or it has
// expired -- callers should treat null as "not logged in."
export async function getDriverPortalSession(): Promise<DriverPortalIdentity | null> {
  const cookieStore = await cookies();
  const token = cookieStore.get(COOKIE_NAME)?.value;
  if (!token) return null;

  const supabase = createServiceRoleClient();
  const { data: session } = await supabase
    .from("driver_portal_sessions")
    .select("driver_id, organization_id, expires_at")
    .eq("token_hash", hashToken(token))
    .maybeSingle();

  if (!session || new Date(session.expires_at) < new Date()) return null;

  const { data: driver } = await supabase
    .from("drivers")
    .select("id, first_name, last_name")
    .eq("id", session.driver_id)
    .maybeSingle();

  if (!driver) return null;

  await supabase
    .from("driver_portal_sessions")
    .update({ last_seen_at: new Date().toISOString() })
    .eq("token_hash", hashToken(token));

  return {
    driverId: driver.id,
    organizationId: session.organization_id,
    firstName: driver.first_name,
    lastName: driver.last_name,
  };
}
