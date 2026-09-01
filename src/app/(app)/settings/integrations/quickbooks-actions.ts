"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentOrgId } from "@/lib/actions/records";
import {
  buildAuthorizeUrl,
  generateOAuthStateToken,
  getQuickbooksRedirectUri,
  isQuickbooksConfigured,
  refreshAccessToken,
  revokeToken,
  QuickbooksReauthRequiredError,
} from "@/lib/integrations/providers/quickbooks";

const LANDING = "/settings/integrations/quickbooks";

// Application-layer owner/admin gate for the user-facing flows. The
// service_role RPCs called below (which handle plaintext tokens) are
// unreachable by a browser/PostgREST session at the database layer -- this
// check just gives a clean error and keeps a non-owner from starting the
// flow at all.
async function requireOwnerOrAdmin(supabase: Awaited<ReturnType<typeof createClient>>) {
  const { data: allowed } = await supabase.rpc("has_role", { p_roles: ["owner", "admin"] });
  if (!allowed) throw new Error("Only an owner or admin can manage the QuickBooks connection.");
}

// Step 1 of connect. Creates a one-time, user+org-bound CSRF state
// (authenticated RPC -- it derives org/user from the session itself) then
// redirects to Intuit's consent screen. The Client Secret is not involved.
export async function startQuickbooksConnect(): Promise<void> {
  if (!isQuickbooksConfigured()) {
    redirect(`${LANDING}?error=not_configured`);
  }
  const supabase = await createClient();
  await requireOwnerOrAdmin(supabase);

  const stateToken = generateOAuthStateToken();
  const { error } = await supabase.rpc("create_quickbooks_oauth_state", {
    p_state_token: stateToken,
    p_redirect_after: LANDING,
  });
  if (error) throw new Error("Could not start the QuickBooks connection.");

  redirect(buildAuthorizeUrl(stateToken));
}

// Disconnect: owner/admin (app layer) -> service_role RPC returns the
// refresh token once for a best-effort Intuit revoke, then the local
// connection is torn down (encrypted columns NULLed inside the RPC).
export async function disconnectQuickbooks(): Promise<void> {
  const supabase = await createClient();
  await requireOwnerOrAdmin(supabase);
  const orgId = await getCurrentOrgId();

  const service = createServiceRoleClient();
  const { data, error } = await service.rpc("disconnect_quickbooks_connection", { p_organization_id: orgId }).maybeSingle();
  if (error) throw new Error("Could not disconnect QuickBooks.");

  const refreshToken = (data as { refresh_token: string | null } | null)?.refresh_token ?? null;
  if (refreshToken) {
    try {
      await revokeToken(refreshToken);
    } catch {
      // Local teardown already succeeded; Intuit-side revoke is best effort.
    }
  }

  revalidatePath(LANDING);
  revalidatePath("/settings/integrations");
}

// Server-side access-token accessor for future sync work. Owner/admin at
// the app layer; all token material moves only through the service_role
// RPCs and stays in this server process. Refreshes (with optimistic
// token_generation guard) when the access token is within 2 minutes of
// expiry. NOT called by any sync yet -- present so the foundation is
// complete and testable.
export async function getQuickbooksAccessToken(): Promise<{ accessToken: string; realmId: string } | null> {
  const supabase = await createClient();
  await requireOwnerOrAdmin(supabase);
  const orgId = await getCurrentOrgId();
  const service = createServiceRoleClient();

  const { data: accessMat, error } = await service
    .rpc("get_quickbooks_access_material", { p_organization_id: orgId })
    .maybeSingle();
  if (error || !accessMat) return null;
  const am = accessMat as {
    access_token: string | null;
    realm_id: string;
    access_token_expires_at: string | null;
    token_generation: number;
    status: string;
  };
  if (am.status !== "connected" || !am.access_token) return null;

  const expiresSoon = am.access_token_expires_at
    ? new Date(am.access_token_expires_at).getTime() - Date.now() < 120_000
    : true;
  if (!expiresSoon) return { accessToken: am.access_token, realmId: am.realm_id };

  // Refresh path -- optimistic concurrency on token_generation.
  const { data: refreshMat } = await service
    .rpc("get_quickbooks_refresh_material", { p_organization_id: orgId })
    .maybeSingle();
  const rm = refreshMat as { refresh_token: string; realm_id: string; token_generation: number } | null;
  if (!rm?.refresh_token) return null;

  let rotated;
  try {
    rotated = await refreshAccessToken(rm.refresh_token);
  } catch (err) {
    if (err instanceof QuickbooksReauthRequiredError) {
      await service.rpc("mark_quickbooks_reconnect_required", { p_organization_id: orgId, p_code: err.code, p_message: err.message });
    }
    return null;
  }

  const { error: writeError } = await service.rpc("refresh_quickbooks_connection", {
    p_organization_id: orgId,
    p_expected_generation: rm.token_generation,
    p_new_access_token: rotated.accessToken,
    p_new_refresh_token: rotated.refreshToken,
    p_access_expires_at: rotated.accessExpiresAt,
    p_refresh_expires_at: rotated.refreshExpiresAt,
  });

  if (writeError) {
    // STALE_REFRESH: another request already rotated the token. Do NOT
    // overwrite it -- reload and use the current credentials.
    if (writeError.message.includes("STALE_REFRESH")) {
      const { data: reread } = await service.rpc("get_quickbooks_access_material", { p_organization_id: orgId }).maybeSingle();
      const rr = reread as { access_token: string | null; realm_id: string; status: string } | null;
      if (rr?.status === "connected" && rr.access_token) return { accessToken: rr.access_token, realmId: rr.realm_id };
    }
    return null;
  }

  return { accessToken: rotated.accessToken, realmId: rm.realm_id };
}

// For the "not configured" UI panel -- shows the exact redirect URI to
// register in Intuit. Returns no secret.
export async function quickbooksSetupInfo(): Promise<{ configured: boolean; redirectUri: string | null }> {
  return { configured: isQuickbooksConfigured(), redirectUri: getQuickbooksRedirectUri() };
}
