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

// ---------------------------------------------------------------------------
// Customer + Invoice + Item (SANDBOX MVP). All server-side; a Bearer access
// token is passed in from getQuickbooksAccessToken() and never logged. Raw
// QuickBooks responses are never surfaced to the client -- only the small
// safe shapes below. Every function returns a typed result, never throws
// for an expected API failure.
// ---------------------------------------------------------------------------

export type QboApiError = { ok: false; code: string; message: string; reauthRequired: boolean };
type QboOk<T> = { ok: true } & T;
export type QboResult<T> = QboOk<T> | QboApiError;

export type QboCustomer = { id: string; displayName: string; companyName: string | null; email: string | null; syncToken: string | null };

function qboHeaders(accessToken: string, write = false): HeadersInit {
  return {
    Authorization: `Bearer ${accessToken}`,
    Accept: "application/json",
    ...(write ? { "Content-Type": "application/json" } : {}),
  };
}

// Extracts a safe error without echoing any sensitive field. QuickBooks
// fault codes are stable identifiers, not secrets.
async function qboError(res: Response): Promise<QboApiError> {
  const reauthRequired = res.status === 401;
  let code = `HTTP_${res.status}`;
  let message = `QuickBooks request failed (${res.status}).`;
  try {
    const j = (await res.json()) as { Fault?: { Error?: { code?: string; Message?: string; Detail?: string }[] } };
    const e = j.Fault?.Error?.[0];
    if (e?.code) code = String(e.code);
    if (e?.Message) message = e.Detail && e.Detail.length < 200 ? `${e.Message}: ${e.Detail}` : e.Message;
  } catch {
    /* keep the generic message -- never dump the raw body */
  }
  if (res.status === 429) code = "RATE_LIMITED";
  return { ok: false, code, message, reauthRequired };
}

function escQuery(v: string): string {
  return v.replace(/['\\]/g, "\\$&");
}

function mapCustomer(c: {
  Id: string;
  DisplayName?: string;
  CompanyName?: string;
  PrimaryEmailAddr?: { Address?: string };
  SyncToken?: string;
}): QboCustomer {
  return {
    id: c.Id,
    displayName: c.DisplayName ?? c.CompanyName ?? "(unnamed)",
    companyName: c.CompanyName ?? null,
    email: c.PrimaryEmailAddr?.Address ?? null,
    syncToken: c.SyncToken ?? null,
  };
}

// Search QuickBooks Customers by display/company name (read-only).
export async function queryCustomers(accessToken: string, realmId: string, term: string): Promise<QboResult<{ customers: QboCustomer[] }>> {
  const t = escQuery(term.trim());
  const q =
    t.length === 0
      ? "select Id, DisplayName, CompanyName, PrimaryEmailAddr, SyncToken from Customer where Active = true orderby DisplayName startposition 1 maxresults 25"
      : `select Id, DisplayName, CompanyName, PrimaryEmailAddr, SyncToken from Customer where DisplayName like '%${t}%' orderby DisplayName startposition 1 maxresults 25`;
  try {
    const res = await fetch(`${apiBaseUrl()}/v3/company/${realmId}/query?query=${encodeURIComponent(q)}`, {
      method: "GET",
      headers: qboHeaders(accessToken),
    });
    if (!res.ok) return qboError(res);
    const j = (await res.json()) as { QueryResponse?: { Customer?: Parameters<typeof mapCustomer>[0][] } };
    return { ok: true, customers: (j.QueryResponse?.Customer ?? []).map(mapCustomer) };
  } catch {
    return { ok: false, code: "NETWORK", message: "Could not reach QuickBooks.", reauthRequired: false };
  }
}

export async function getCustomerById(accessToken: string, realmId: string, id: string): Promise<QboResult<{ customer: QboCustomer }>> {
  try {
    const res = await fetch(`${apiBaseUrl()}/v3/company/${realmId}/customer/${encodeURIComponent(id)}`, {
      method: "GET",
      headers: qboHeaders(accessToken),
    });
    if (!res.ok) return qboError(res);
    const j = (await res.json()) as { Customer?: Parameters<typeof mapCustomer>[0] };
    if (!j.Customer) return { ok: false, code: "NOT_FOUND", message: "QuickBooks customer not found.", reauthRequired: false };
    return { ok: true, customer: mapCustomer(j.Customer) };
  } catch {
    return { ok: false, code: "NETWORK", message: "Could not reach QuickBooks.", reauthRequired: false };
  }
}

// Create a QuickBooks Customer. If QBO rejects it as a duplicate
// DisplayName, adopt the existing one (idempotent under double-click /
// partial-persistence).
export async function createCustomer(
  accessToken: string,
  realmId: string,
  input: { displayName: string; companyName?: string | null; email?: string | null }
): Promise<QboResult<{ customer: QboCustomer; adopted: boolean }>> {
  const body: Record<string, unknown> = { DisplayName: input.displayName };
  if (input.companyName) body.CompanyName = input.companyName;
  if (input.email) body.PrimaryEmailAddr = { Address: input.email };
  try {
    const res = await fetch(`${apiBaseUrl()}/v3/company/${realmId}/customer`, {
      method: "POST",
      headers: qboHeaders(accessToken, true),
      body: JSON.stringify(body),
    });
    if (res.ok) {
      const j = (await res.json()) as { Customer?: Parameters<typeof mapCustomer>[0] };
      if (!j.Customer) return { ok: false, code: "BAD_RESPONSE", message: "QuickBooks returned no customer.", reauthRequired: false };
      return { ok: true, customer: mapCustomer(j.Customer), adopted: false };
    }
    const err = await qboError(res);
    // 6240 = Duplicate Name Exists Error.
    if (err.code === "6240" || /duplicate name/i.test(err.message)) {
      const found = await queryCustomers(accessToken, realmId, input.displayName);
      if (found.ok) {
        const exact = found.customers.find((c) => c.displayName.toLowerCase() === input.displayName.toLowerCase());
        if (exact) return { ok: true, customer: exact, adopted: true };
      }
    }
    return err;
  } catch {
    return { ok: false, code: "NETWORK", message: "Could not reach QuickBooks.", reauthRequired: false };
  }
}

// One shared "Freight Transportation" service Item per org (never one per
// load). Finds it by name, else creates it. The caller persists the
// returned id into integration_settings.config.
export async function findOrCreateFreightItem(accessToken: string, realmId: string): Promise<QboResult<{ itemId: string }>> {
  const name = "Freight Transportation";
  try {
    const q = `select Id, Name from Item where Name = '${escQuery(name)}' and Type = 'Service'`;
    const findRes = await fetch(`${apiBaseUrl()}/v3/company/${realmId}/query?query=${encodeURIComponent(q)}`, {
      method: "GET",
      headers: qboHeaders(accessToken),
    });
    if (findRes.ok) {
      const j = (await findRes.json()) as { QueryResponse?: { Item?: { Id: string }[] } };
      const hit = j.QueryResponse?.Item?.[0];
      if (hit?.Id) return { ok: true, itemId: hit.Id };
    } else if (findRes.status === 401) {
      return qboError(findRes);
    }
    // Need an income account for a Service item; pick the first active one.
    const acctRes = await fetch(
      `${apiBaseUrl()}/v3/company/${realmId}/query?query=${encodeURIComponent(
        "select Id from Account where AccountType = 'Income' and Active = true maxresults 1"
      )}`,
      { method: "GET", headers: qboHeaders(accessToken) }
    );
    if (!acctRes.ok) return qboError(acctRes);
    const acctJson = (await acctRes.json()) as { QueryResponse?: { Account?: { Id: string }[] } };
    const incomeAccountId = acctJson.QueryResponse?.Account?.[0]?.Id;
    if (!incomeAccountId) {
      return { ok: false, code: "NO_INCOME_ACCOUNT", message: "No income account exists in the QuickBooks sandbox company.", reauthRequired: false };
    }
    const createRes = await fetch(`${apiBaseUrl()}/v3/company/${realmId}/item`, {
      method: "POST",
      headers: qboHeaders(accessToken, true),
      body: JSON.stringify({ Name: name, Type: "Service", IncomeAccountRef: { value: incomeAccountId } }),
    });
    if (!createRes.ok) {
      const err = await qboError(createRes);
      if (err.code === "6240") {
        const retry = await fetch(`${apiBaseUrl()}/v3/company/${realmId}/query?query=${encodeURIComponent(q)}`, {
          method: "GET",
          headers: qboHeaders(accessToken),
        });
        if (retry.ok) {
          const rj = (await retry.json()) as { QueryResponse?: { Item?: { Id: string }[] } };
          if (rj.QueryResponse?.Item?.[0]?.Id) return { ok: true, itemId: rj.QueryResponse.Item[0].Id };
        }
      }
      return err;
    }
    const cj = (await createRes.json()) as { Item?: { Id: string } };
    if (!cj.Item?.Id) return { ok: false, code: "BAD_RESPONSE", message: "QuickBooks returned no item.", reauthRequired: false };
    return { ok: true, itemId: cj.Item.Id };
  } catch {
    return { ok: false, code: "NETWORK", message: "Could not reach QuickBooks.", reauthRequired: false };
  }
}

export type QboInvoiceRef = { id: string; docNumber: string | null; syncToken: string | null };

// Look up a QBO invoice by DocNumber (= local invoice_number). Used before
// create so a partial-persistence failure can adopt rather than duplicate.
export async function findInvoiceByDocNumber(accessToken: string, realmId: string, docNumber: string): Promise<QboResult<{ invoice: QboInvoiceRef | null }>> {
  try {
    const q = `select Id, DocNumber, SyncToken from Invoice where DocNumber = '${escQuery(docNumber)}'`;
    const res = await fetch(`${apiBaseUrl()}/v3/company/${realmId}/query?query=${encodeURIComponent(q)}`, {
      method: "GET",
      headers: qboHeaders(accessToken),
    });
    if (!res.ok) return qboError(res);
    const j = (await res.json()) as { QueryResponse?: { Invoice?: { Id: string; DocNumber?: string; SyncToken?: string }[] } };
    const hit = j.QueryResponse?.Invoice?.[0];
    return { ok: true, invoice: hit ? { id: hit.Id, docNumber: hit.DocNumber ?? null, syncToken: hit.SyncToken ?? null } : null };
  } catch {
    return { ok: false, code: "NETWORK", message: "Could not reach QuickBooks.", reauthRequired: false };
  }
}

export type QboInvoiceInput = {
  customerId: string;
  itemId: string;
  docNumber: string;
  txnDate: string; // YYYY-MM-DD
  dueDate: string | null; // YYYY-MM-DD
  lineDescription: string;
  amount: number;
  customerEmail: string | null;
};

// Create a QuickBooks Invoice. Conservative: one line, no tax lines, the
// mapped CustomerRef + shared freight Item. Never sends settlements /
// payables / fuel / deductions.
export async function createInvoice(accessToken: string, realmId: string, input: QboInvoiceInput): Promise<QboResult<{ invoice: QboInvoiceRef }>> {
  const body: Record<string, unknown> = {
    CustomerRef: { value: input.customerId },
    DocNumber: input.docNumber,
    TxnDate: input.txnDate,
    Line: [
      {
        DetailType: "SalesItemLineDetail",
        Amount: Number(input.amount.toFixed(2)),
        Description: input.lineDescription,
        SalesItemLineDetail: { ItemRef: { value: input.itemId }, Qty: 1, UnitPrice: Number(input.amount.toFixed(2)) },
      },
    ],
  };
  if (input.dueDate) body.DueDate = input.dueDate;
  if (input.customerEmail) body.BillEmail = { Address: input.customerEmail };
  try {
    const res = await fetch(`${apiBaseUrl()}/v3/company/${realmId}/invoice`, {
      method: "POST",
      headers: qboHeaders(accessToken, true),
      body: JSON.stringify(body),
    });
    if (!res.ok) return qboError(res);
    const j = (await res.json()) as { Invoice?: { Id: string; DocNumber?: string; SyncToken?: string } };
    if (!j.Invoice?.Id) return { ok: false, code: "BAD_RESPONSE", message: "QuickBooks returned no invoice.", reauthRequired: false };
    return { ok: true, invoice: { id: j.Invoice.Id, docNumber: j.Invoice.DocNumber ?? null, syncToken: j.Invoice.SyncToken ?? null } };
  } catch {
    return { ok: false, code: "NETWORK", message: "Could not reach QuickBooks.", reauthRequired: false };
  }
}
