import "server-only";
import { Resend } from "resend";
import { EMAIL_PROVIDER_CONFIGURED } from "@/lib/email/provider";

// The ONE place that talks to Resend's Domains API -- mirrors
// src/lib/email/provider.ts's own role for emails.send(). Every domain
// create/verify/remove call in this app goes through here, never a raw
// `new Resend(...)` scattered into a server action (spec section 1/16).
let _client: Resend | null = null;
function client(): Resend {
  if (!_client) _client = new Resend(process.env.RESEND_API_KEY);
  return _client;
}

// ---------------------------------------------------------------------------
// Domain normalization (spec section 40). Strips scheme/path/whitespace,
// rejects anything that isn't a bare hostname -- this value eventually
// becomes both a DNS name AND a provider API argument, so it must never be
// arbitrary user input passed through unchecked.
// ---------------------------------------------------------------------------
const DOMAIN_RE = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;

export type NormalizeResult = { ok: true; domain: string } | { ok: false; error: string };

export function normalizeDomain(raw: string): NormalizeResult {
  let value = raw.trim().toLowerCase();
  if (!value) return { ok: false, error: "Domain is required." };

  // Strip a scheme if someone pastes a full URL.
  value = value.replace(/^https?:\/\//, "");
  // Strip a trailing slash / path.
  value = value.split("/")[0];
  // Reject an email address pasted by mistake.
  if (value.includes("@")) return { ok: false, error: "Enter a domain (e.g. kalifreights.com), not an email address." };
  // Reject a port.
  if (value.includes(":")) return { ok: false, error: "Enter a plain domain without a port." };
  value = value.trim();

  if (!DOMAIN_RE.test(value)) return { ok: false, error: "That doesn't look like a valid domain (e.g. kalifreights.com)." };
  if (value.length > 253) return { ok: false, error: "Domain is too long." };

  return { ok: true, domain: value };
}

// Given a root domain, derive the recommended sending SUBDOMAIN (spec
// section 6) -- a tenant's normal website/email (kalifreights.com's own
// MX/SPF) is never touched; Resend sends through a dedicated subdomain
// instead. "mail." is the convention shown throughout this phase's spec;
// exposed as its own function so Settings can display/allow overriding it
// before the domain is actually created.
export function defaultSendingDomain(rootDomain: string): string {
  return `mail.${rootDomain}`;
}

// ---------------------------------------------------------------------------
// Structured DNS record shape persisted in organization_email_domains.
// dns_records -- a safe, curated projection of Resend's own DomainRecords
// union (SPF/DKIM/tracking), never the full raw API response.
// ---------------------------------------------------------------------------
export type DnsRecord = {
  record: string; // "SPF" | "DKIM" | ...
  type: string; // "TXT" | "MX" | "CNAME"
  name: string;
  value: string;
  ttl: string;
  priority?: number;
  status: string; // Resend's own per-record verification status
};

export type ProviderResult<T> = { ok: true; data: T } | { ok: false; error: string; code?: string };

// Sender eligibility rule (spec review item 2): the installed Resend SDK's
// Domain object carries TWO separate signals --
//   status: 'not_started'|'pending'|'verified'|'failed'|'partially_verified'|'partially_failed'
//   capabilities: { sending: 'enabled'|'disabled', receiving: 'enabled'|'disabled' }
// `status` describes the domain's OVERALL DNS verification outcome (SPF,
// DKIM, tracking CNAME, DMARC, etc. all rolled together); capabilities.
// sending is the field that actually tells us whether OUTBOUND SENDING
// itself is authorized right now. These can legitimately diverge -- e.g.
// a domain can show 'partially_verified' overall (a non-sending-related
// record, like a tracking CNAME, still pending) while capabilities.sending
// is already 'enabled', because sending only requires SPF+DKIM. The
// reverse is also possible in principle. The rule this module enforces:
// a domain is sender-eligible IF AND ONLY IF capabilities.sending ===
// 'enabled', regardless of what the overall `status` string says. status
// is still stored and shown in Settings (spec section 12), but
// resolveEmailSender() (sender-resolver.ts) gates ONLY on
// sending_enabled, never on status alone -- so an ambiguous
// 'partially_verified' domain is used only when the provider has
// PROVEN the sending capability itself is live, never inferred from the
// overall status being "close enough".
function extractSendingEnabled(capabilities: { sending?: string } | undefined): boolean {
  return capabilities?.sending === "enabled";
}

function friendlyResendError(message: string): string {
  const lower = message.toLowerCase();
  if (lower.includes("already exists") || lower.includes("duplicate")) return "This domain is already registered.";
  if (lower.includes("api key is invalid") || lower.includes("unauthorized")) return "The platform email provider is not configured correctly. Contact support.";
  if (lower.includes("rate limit")) return "The email provider is rate-limited right now -- try again shortly.";
  return "The email provider could not complete this request.";
}

// Creates the domain in the ONE central Resend account (spec section 10).
// Never called with a tenant-supplied Resend credential -- there isn't one.
export async function createResendDomain(sendingDomain: string): Promise<ProviderResult<{ resendDomainId: string; status: string; sendingEnabled: boolean; records: DnsRecord[] }>> {
  if (!EMAIL_PROVIDER_CONFIGURED) return { ok: false, error: "Email provider not configured.", code: "NOT_CONFIGURED" };
  try {
    const { data, error } = await client().domains.create({ name: sendingDomain });
    if (error) return { ok: false, error: friendlyResendError(error.message), code: error.name ?? "PROVIDER_ERROR" };
    if (!data) return { ok: false, error: "The email provider returned no domain data." };
    return {
      ok: true,
      data: {
        resendDomainId: data.id,
        status: data.status,
        sendingEnabled: extractSendingEnabled(data.capabilities),
        records: (data.records ?? []).map((r) => ({
          record: "record" in r ? String(r.record) : "UNKNOWN",
          type: r.type,
          name: r.name,
          value: r.value,
          ttl: r.ttl,
          priority: "priority" in r ? r.priority : undefined,
          status: r.status,
        })),
      },
    };
  } catch (err) {
    return { ok: false, error: err instanceof Error ? friendlyResendError(err.message) : "Could not reach the email provider." };
  }
}

// Real, provider-confirmed verification check (spec section 11) -- never
// lets a user manually flip "verified" locally (spec section 11 explicit
// prohibition).
export async function checkResendDomainVerification(resendDomainId: string): Promise<ProviderResult<{ status: string; sendingEnabled: boolean; records: DnsRecord[] }>> {
  if (!EMAIL_PROVIDER_CONFIGURED) return { ok: false, error: "Email provider not configured.", code: "NOT_CONFIGURED" };
  try {
    // verify() asks Resend to re-check DNS right now; get() then returns
    // the resulting (possibly still-pending) status + records. Calling
    // verify() first means "Check Verification" in the UI genuinely
    // triggers a fresh DNS lookup, not just a cached read.
    await client().domains.verify(resendDomainId);
    const { data, error } = await client().domains.get(resendDomainId);
    if (error) return { ok: false, error: friendlyResendError(error.message), code: error.name ?? "PROVIDER_ERROR" };
    if (!data) return { ok: false, error: "The email provider returned no domain data." };
    return {
      ok: true,
      data: {
        status: data.status,
        sendingEnabled: extractSendingEnabled(data.capabilities),
        records: (data.records ?? []).map((r) => ({
          record: "record" in r ? String(r.record) : "UNKNOWN",
          type: r.type,
          name: r.name,
          value: r.value,
          ttl: r.ttl,
          priority: "priority" in r ? r.priority : undefined,
          status: r.status,
        })),
      },
    };
  } catch (err) {
    return { ok: false, error: err instanceof Error ? friendlyResendError(err.message) : "Could not reach the email provider." };
  }
}

// Best-effort provider-side removal (spec section 38) -- the LOCAL row is
// always what the caller disables regardless of this result, so a
// provider outage never blocks a tenant from disconnecting a domain in
// their own Settings.
export async function removeResendDomain(resendDomainId: string): Promise<ProviderResult<{ deleted: boolean }>> {
  if (!EMAIL_PROVIDER_CONFIGURED) return { ok: false, error: "Email provider not configured.", code: "NOT_CONFIGURED" };
  try {
    const { data, error } = await client().domains.remove(resendDomainId);
    if (error) return { ok: false, error: friendlyResendError(error.message), code: error.name ?? "PROVIDER_ERROR" };
    return { ok: true, data: { deleted: data?.deleted ?? false } };
  } catch (err) {
    return { ok: false, error: err instanceof Error ? friendlyResendError(err.message) : "Could not reach the email provider." };
  }
}
