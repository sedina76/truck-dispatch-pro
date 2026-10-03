// Settings -> Email & Sending Domain helpers (pure; unit-tested).

/** Per-DNS-record status from the email provider, in plain words. */
export const DNS_RECORD_STATUS_LABEL: Record<string, string> = {
  not_started: "Not checked yet",
  pending: "Checking",
  verified: "Verified",
  failed: "Not found",
  temporary_failure: "Retrying",
};

export function dnsRecordStatusLabel(status: string | null | undefined): string {
  if (!status) return "Not checked yet";
  return DNS_RECORD_STATUS_LABEL[status] ?? status.replace(/_/g, " ").replace(/^\w/, (c) => c.toUpperCase());
}

type Existing = { organization_id: string; disabled_at: string | null } | null;

/**
 * Adding a sending domain. A REMOVED domain keeps its row (send history),
 * and sending_domain is globally unique -- so re-adding the same domain
 * must reactivate that row instead of failing as "already added".
 */
export function addDomainDecision(existing: Existing, organizationId: string): { action: "create" } | { action: "reactivate" } | { action: "refuse"; error: string } {
  if (!existing) return { action: "create" };
  if (existing.organization_id !== organizationId) return { action: "refuse", error: "This sending domain is already in use by another account." };
  if (existing.disabled_at) return { action: "reactivate" };
  return { action: "refuse", error: "This sending domain is already added to your organization." };
}
