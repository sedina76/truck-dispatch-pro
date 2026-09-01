import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentOrgId } from "@/lib/actions/records";
import {
  exchangeCodeForTokens,
  fetchCompanyInfo,
  QUICKBOOKS_SCOPES,
} from "@/lib/integrations/providers/quickbooks";

// Canonical QuickBooks Online OAuth 2.0 callback.
//   Registered redirect URI:
//   https://truck-dispatch-pro.vercel.app/api/integrations/quickbooks/callback
//
// State validation runs on the USER's session (createClient / cookies) so
// it can bind + verify user+org. Token exchange and persistence then move
// onto the SERVICE-ROLE client: the plaintext-token RPCs
// (store_quickbooks_connection, record_quickbooks_test_result) are
// service_role-only at the database layer, so a browser session can never
// reach them. No token is ever placed in the redirect URL, a cookie
// readable by JS, a log line, or the rendered page. Every failure sends
// the browser to /settings/integrations/quickbooks?error=<short_code> --
// never raw Intuit error text.

const LANDING = "/settings/integrations/quickbooks";

function fail(req: NextRequest, code: string): NextResponse {
  return NextResponse.redirect(new URL(`${LANDING}?error=${encodeURIComponent(code)}`, req.url));
}

function safeRelativePath(value: string | null | undefined): string {
  if (!value || !value.startsWith("/") || value.startsWith("//")) return LANDING;
  return value;
}

export async function GET(req: NextRequest) {
  const sp = req.nextUrl.searchParams;
  const intuitError = sp.get("error");
  const code = sp.get("code");
  const state = sp.get("state");
  const realmId = sp.get("realmId");

  // 1. Intuit-reported errors / missing required params.
  if (intuitError) return fail(req, intuitError === "access_denied" ? "access_denied" : "intuit_error");
  if (!state) return fail(req, "missing_state");
  if (!code) return fail(req, "missing_code");
  if (!realmId) return fail(req, "missing_realm");

  // 2. Must be an authenticated session.
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return NextResponse.redirect(new URL("/login", req.url));

  let orgId: string;
  try {
    orgId = await getCurrentOrgId();
  } catch {
    return fail(req, "no_org");
  }

  // 3. Consume the one-time state (authenticated RPC: verifies the state
  //    belongs to THIS session's user+org, then marks it used -- a
  //    mismatched session is rejected without burning the state).
  const { data: consumed, error: stateError } = await supabase
    .rpc("consume_quickbooks_oauth_state", { p_state_token: state })
    .maybeSingle();
  if (stateError || !consumed) return fail(req, "invalid_state");
  const stateRow = consumed as { organization_id: string; created_by: string; redirect_after: string | null };

  // 4. Belt-and-suspenders bind re-check.
  if (stateRow.organization_id !== orgId || stateRow.created_by !== user.id) {
    return fail(req, "org_mismatch");
  }

  // 5. Server-side authorization-code exchange.
  let tokens;
  try {
    tokens = await exchangeCodeForTokens(code);
  } catch {
    return fail(req, "exchange_failed");
  }

  // 6. Read-only validation: CompanyInfo. A rejected token => do not
  //    persist a dead connection.
  const info = await fetchCompanyInfo(tokens.accessToken, realmId);
  if (!info.ok && info.reauthRequired) {
    return fail(req, "token_invalid");
  }

  // 7. Persist (encrypted) + mirror non-secret state -- SERVICE ROLE.
  const service = createServiceRoleClient();
  const { error: storeError } = await service.rpc("store_quickbooks_connection", {
    p_organization_id: orgId,
    p_actor_id: user.id,
    p_realm_id: realmId,
    p_access_token: tokens.accessToken,
    p_refresh_token: tokens.refreshToken,
    p_access_expires_at: tokens.accessExpiresAt,
    p_refresh_expires_at: tokens.refreshExpiresAt,
    p_scopes: QUICKBOOKS_SCOPES,
    p_company_name: info.ok ? info.companyName : null,
  });
  if (storeError) {
    return fail(req, storeError.message.includes("different organization") ? "realm_taken" : "store_failed");
  }

  // 8. Record the read-only test outcome (non-fatal).
  await service.rpc("record_quickbooks_test_result", {
    p_organization_id: orgId,
    p_ok: info.ok,
    p_message: info.ok ? `Connected to "${info.companyName}".` : info.message,
  });

  const dest = new URL(safeRelativePath(stateRow.redirect_after), req.url);
  dest.searchParams.set("connected", "1");
  return NextResponse.redirect(dest);
}
