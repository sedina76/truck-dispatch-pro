import "server-only";
import { randomBytes } from "crypto";

// QuickBooks Online (Intuit) OAuth 2.0 -- SANDBOX/DEVELOPMENT foundation.
// Server-only. Client ID/Secret are read from server env vars and never
// leave this module's process. No token, authorization code, or Basic
// Authorization header is ever returned to the browser or written to a log.
//
// This module does NOT touch the database. Persistence is entirely through
// the SECURITY DEFINER RPCs added by migration 0116
// (create/consume_quickbooks_oauth_state, store_quickbooks_connection,
// get_quickbooks_*_material, refresh_quickbooks_connection, ...). Until
// 0116 is applied and the QUICKBOOKS_* env vars are set, isConfigured()
// returns false and the UI shows a "configuration required" panel instead
// of a Connect button.

export const QUICKBOOKS_SCOPES = "com.intuit.quickbooks.accounting";
const CALLBACK_PATH = "/api/integrations/quickbooks/callback";

const AUTHORIZE_URL = "https://appcenter.intuit.com/connect/oauth2";
const TOKEN_URL = "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer";
const REVOKE_URL = "https://developer.api.intuit.com/v2/oauth2/tokens/revoke";

function apiBaseUrl(): string {
  return quickbooksEnvironment() === "production"
    ? "https://quickbooks.api.intuit.com"
    : "https://sandbox-quickbooks.api.intuit.com";
}

export function quickbooksEnvironment(): "sandbox" | "production" {
  return process.env.QUICKBOOKS_ENVIRONMENT === "production" ? "production" : "sandbox";
}

// The redirect URI MUST be byte-for-byte identical in the authorize request,
// the token exchange, and the value registered in the Intuit Developer
// portal. Prefer an explicit server-only env var; fall back to
// NEXT_PUBLIC_SITE_URL + the canonical path for local dev only.
export function getQuickbooksRedirectUri(): string | null {
  const explicit = (process.env.QUICKBOOKS_REDIRECT_URI ?? "").trim();
  if (explicit) {
    try {
      const u = new URL(explicit);
      if (u.protocol === "https:" || u.hostname === "localhost" || u.hostname === "127.0.0.1") return explicit;
    } catch {
      return null;
    }
    return null;
  }
  const site = (process.env.NEXT_PUBLIC_SITE_URL ?? "").trim();
  if (!site) return null;
  try {
    return new URL(CALLBACK_PATH, site).toString();
  } catch {
    return null;
  }
}

export function isQuickbooksConfigured(): boolean {
  return Boolean(
    (process.env.QUICKBOOKS_CLIENT_ID ?? "").trim() &&
      (process.env.QUICKBOOKS_CLIENT_SECRET ?? "").trim() &&
      getQuickbooksRedirectUri()
  );
}

function requireConfig(): { clientId: string; clientSecret: string; redirectUri: string } {
  const clientId = (process.env.QUICKBOOKS_CLIENT_ID ?? "").trim();
  const clientSecret = (process.env.QUICKBOOKS_CLIENT_SECRET ?? "").trim();
  const redirectUri = getQuickbooksRedirectUri();
  if (!clientId || !clientSecret || !redirectUri) {
    throw new Error("QuickBooks is not configured (QUICKBOOKS_CLIENT_ID / QUICKBOOKS_CLIENT_SECRET / redirect URI).");
  }
  return { clientId, clientSecret, redirectUri };
}

export function generateOAuthStateToken(): string {
  return randomBytes(32).toString("base64url");
}

export function buildAuthorizeUrl(stateToken: string): string {
  const { clientId, redirectUri } = requireConfig();
  const params = new URLSearchParams({
    client_id: clientId,
    response_type: "code",
    scope: QUICKBOOKS_SCOPES,
    redirect_uri: redirectUri,
    state: stateToken,
  });
  return `${AUTHORIZE_URL}?${params.toString()}`;
}

function basicAuthHeader(): string {
  const { clientId, clientSecret } = requireConfig();
  return "Basic " + Buffer.from(`${clientId}:${clientSecret}`).toString("base64");
}

export type QuickbooksTokens = {
  accessToken: string;
  refreshToken: string;
  accessExpiresAt: string; // ISO
  refreshExpiresAt: string | null; // ISO
  tokenType: string;
};

type IntuitTokenResponse = {
  access_token?: string;
  refresh_token?: string;
  expires_in?: number;
  x_refresh_token_expires_in?: number;
  token_type?: string;
  error?: string;
  error_description?: string;
};

function toTokens(json: IntuitTokenResponse): QuickbooksTokens {
  if (!json.access_token || !json.refresh_token) {
    throw new Error("Intuit token response was missing token material.");
  }
  const now = Date.now();
  return {
    accessToken: json.access_token,
    refreshToken: json.refresh_token,
    accessExpiresAt: new Date(now + (json.expires_in ?? 3600) * 1000).toISOString(),
    refreshExpiresAt: json.x_refresh_token_expires_in
      ? new Date(now + json.x_refresh_token_expires_in * 1000).toISOString()
      : null,
    tokenType: json.token_type ?? "bearer",
  };
}

// invalid_grant on refresh => the connection needs full re-authorization.
export class QuickbooksReauthRequiredError extends Error {
  code = "REAUTH_REQUIRED";
}

export async function exchangeCodeForTokens(code: string): Promise<QuickbooksTokens> {
  const { redirectUri } = requireConfig();
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: {
      Authorization: basicAuthHeader(),
      "Content-Type": "application/x-www-form-urlencoded",
      Accept: "application/json",
    },
    body: new URLSearchParams({ grant_type: "authorization_code", code, redirect_uri: redirectUri }).toString(),
  });
  const json = (await res.json().catch(() => ({}))) as IntuitTokenResponse;
  if (!res.ok) {
    // Never include the code or any token in the surfaced message.
    throw new Error(`Intuit rejected the authorization code (${res.status} ${json.error ?? "error"}).`);
  }
  return toTokens(json);
}

export async function refreshAccessToken(refreshToken: string): Promise<QuickbooksTokens> {
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: {
      Authorization: basicAuthHeader(),
      "Content-Type": "application/x-www-form-urlencoded",
      Accept: "application/json",
    },
    body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: refreshToken }).toString(),
  });
  const json = (await res.json().catch(() => ({}))) as IntuitTokenResponse;
  if (!res.ok) {
    if (json.error === "invalid_grant" || res.status === 400) {
      throw new QuickbooksReauthRequiredError("QuickBooks refresh token is no longer valid.");
    }
    throw new Error(`Intuit token refresh failed (${res.status}).`);
  }
  return toTokens(json);
}

// Best-effort revoke at Intuit. Failure is swallowed by the caller -- the
// local connection is torn down regardless.
export async function revokeToken(token: string): Promise<void> {
  await fetch(REVOKE_URL, {
    method: "POST",
    headers: {
      Authorization: basicAuthHeader(),
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({ token }),
  });
}

export type CompanyInfoResult =
  | { ok: true; companyName: string }
  | { ok: false; message: string; reauthRequired: boolean };

// READ-ONLY validation call. Confirms the access token + realm id are
// valid and the (sandbox) company is reachable. Creates/reads/writes
// nothing in QuickBooks.
export async function fetchCompanyInfo(accessToken: string, realmId: string): Promise<CompanyInfoResult> {
  try {
    const res = await fetch(`${apiBaseUrl()}/v3/company/${realmId}/companyinfo/${realmId}`, {
      method: "GET",
      headers: { Authorization: `Bearer ${accessToken}`, Accept: "application/json" },
    });
    if (res.status === 401) {
      return { ok: false, message: "QuickBooks rejected the access token.", reauthRequired: true };
    }
    if (!res.ok) {
      return { ok: false, message: `QuickBooks CompanyInfo request failed (${res.status}).`, reauthRequired: false };
    }
    const json = (await res.json().catch(() => ({}))) as { CompanyInfo?: { CompanyName?: string } };
    return { ok: true, companyName: json.CompanyInfo?.CompanyName ?? "QuickBooks Company" };
  } catch {
    return { ok: false, message: "Could not reach QuickBooks.", reauthRequired: false };
  }
}
