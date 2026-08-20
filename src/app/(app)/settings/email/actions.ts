"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentOrgId } from "@/lib/actions/records";
import { normalizeDomain, defaultSendingDomain, createResendDomain, checkResendDomainVerification, removeResendDomain } from "@/lib/email/domains";

export type EmailActionResult = { ok: true } | { ok: false; error: string };

// Every action here first re-derives organizationId from the authenticated
// session (never trusts a client-supplied one, spec section 45), then
// requires owner/admin before touching anything (spec section 44), then
// independently re-verifies that the domain/sender row being acted on
// actually belongs to THAT organization (spec section 37/46) -- a
// cross-org id simply returns "not found" under this same-org filter,
// exactly like every other Phase 2A-2E ownership check in this codebase.
async function requireEmailAdmin(): Promise<{ organizationId: string; userId: string } | { error: string }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "Not authenticated." };

  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return { error: "No organization on this account." };
  }

  const { data: profile } = await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle();
  if (!profile || !["owner", "admin"].includes(profile.role)) {
    return { error: "Only an owner or admin can manage email sending domains." };
  }

  return { organizationId, userId: user.id };
}

async function logEmailActivity(organizationId: string, action: string, changes: Record<string, unknown>) {
  const service = createServiceRoleClient();
  const { error } = await service.rpc("log_activity", {
    p_entity_type: "organization",
    p_entity_id: organizationId,
    p_action: action,
    p_changes: changes,
    p_organization_id: organizationId,
  });
  if (error) console.error("[settings/email] log_activity failed:", error);
}

// ---------------------------------------------------------------------------
// Domain creation flow (spec section 10).
// ---------------------------------------------------------------------------
export async function addEmailDomain(formData: FormData): Promise<EmailActionResult> {
  const auth = await requireEmailAdmin();
  if ("error" in auth) return { ok: false, error: auth.error };
  const { organizationId, userId } = auth;

  const rawDomain = String(formData.get("domain") || "");
  const normalized = normalizeDomain(rawDomain);
  if (!normalized.ok) return { ok: false, error: normalized.error };

  const rawSendingDomain = String(formData.get("sending_domain") || "").trim();
  const sendingDomain = rawSendingDomain ? normalizeDomain(rawSendingDomain) : { ok: true as const, domain: defaultSendingDomain(normalized.domain) };
  if (!sendingDomain.ok) return { ok: false, error: sendingDomain.error };

  const service = createServiceRoleClient();

  // Global uniqueness is also DB-enforced (organization_email_domains_
  // sending_domain_key) -- this pre-check just gives a clean message
  // instead of a raw constraint-violation error.
  const { data: existingGlobal } = await service.from("organization_email_domains").select("id, organization_id").eq("sending_domain", sendingDomain.domain).maybeSingle();
  if (existingGlobal) {
    return {
      ok: false,
      error: existingGlobal.organization_id === organizationId ? "This sending domain is already added to your organization." : "This sending domain is already in use by another account.",
    };
  }

  const created = await createResendDomain(sendingDomain.domain);
  if (!created.ok) return { ok: false, error: created.error };

  const { count } = await service.from("organization_email_domains").select("id", { count: "exact", head: true }).eq("organization_id", organizationId);
  const isFirstDomain = (count ?? 0) === 0;

  const { error: insertError } = await service.from("organization_email_domains").insert({
    organization_id: organizationId,
    domain: normalized.domain,
    sending_domain: sendingDomain.domain,
    resend_domain_id: created.data.resendDomainId,
    status: created.data.status,
    sending_enabled: created.data.sendingEnabled,
    dns_records: created.data.records,
    is_default: isFirstDomain,
    created_by: userId,
  });
  if (insertError) return { ok: false, error: "Domain was created with the provider but could not be saved. Contact support." };

  await logEmailActivity(organizationId, "email_domain_added", { domain: normalized.domain, sending_domain: sendingDomain.domain });
  revalidatePath("/settings/email");
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Verification flow (spec section 11) -- never lets the user manually flip
// "verified"; always a fresh, real provider-confirmed check.
// ---------------------------------------------------------------------------
export async function checkEmailDomainVerification(domainId: string): Promise<EmailActionResult> {
  const auth = await requireEmailAdmin();
  if ("error" in auth) return { ok: false, error: auth.error };
  const { organizationId } = auth;

  const service = createServiceRoleClient();
  const { data: domain } = await service.from("organization_email_domains").select("id, resend_domain_id, status").eq("id", domainId).eq("organization_id", organizationId).maybeSingle();
  if (!domain) return { ok: false, error: "Domain not found." };
  if (!domain.resend_domain_id) return { ok: false, error: "This domain has no provider record to check." };

  const result = await checkResendDomainVerification(domain.resend_domain_id);
  if (!result.ok) return { ok: false, error: result.error };

  const wasVerified = domain.status === "verified";
  const isNowVerified = result.data.status === "verified";

  const { error: updateError } = await service
    .from("organization_email_domains")
    .update({
      status: result.data.status,
      sending_enabled: result.data.sendingEnabled,
      dns_records: result.data.records,
      verified_at: isNowVerified ? new Date().toISOString() : null,
    })
    .eq("id", domainId);
  if (updateError) return { ok: false, error: "Could not save the updated verification status." };

  if (!wasVerified && isNowVerified) {
    await logEmailActivity(organizationId, "email_domain_verified", { domain_id: domainId });
  }
  revalidatePath("/settings/email");
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Domain removal (spec section 38) -- soft-disable only. Historical
// email_send_log.domain_id keeps pointing at this row (on delete set
// null only if the row is ever hard-deleted, which this action never
// does), so past send history stays fully intact and attributable.
// ---------------------------------------------------------------------------
export async function removeEmailDomain(domainId: string): Promise<EmailActionResult> {
  const auth = await requireEmailAdmin();
  if ("error" in auth) return { ok: false, error: auth.error };
  const { organizationId } = auth;

  const service = createServiceRoleClient();
  const { data: domain } = await service.from("organization_email_domains").select("id, resend_domain_id, domain").eq("id", domainId).eq("organization_id", organizationId).maybeSingle();
  if (!domain) return { ok: false, error: "Domain not found." };

  // Best-effort provider-side removal -- a provider failure never blocks
  // the tenant from disconnecting it locally (spec section 38).
  if (domain.resend_domain_id) {
    const removed = await removeResendDomain(domain.resend_domain_id);
    if (!removed.ok) console.warn(`[settings/email] provider-side domain removal failed for ${domainId}:`, removed.error);
  }

  // sending_enabled: false HERE, not just status/disabled_at, is the
  // actual fix (found live during Phase 2F post-migration verification):
  // resolveEmailSender()'s eligibility filter gates ONLY on
  // sending_enabled (spec review item 2 -- deliberately never on
  // `status`), so leaving sending_enabled untouched on a disabled domain
  // meant a sender reactivated later via updateEmailSender() below would
  // have been treated as fully eligible again by the real send pipeline,
  // even though the domain was explicitly disabled and its Resend-side
  // registration may already be gone. sending_enabled must stay the one
  // authoritative, always-current signal everywhere a domain's row is
  // written, not just where it's read.
  const { error: updateError } = await service.from("organization_email_domains").update({ status: "disabled", disabled_at: new Date().toISOString(), is_default: false, sending_enabled: false }).eq("id", domainId);
  if (updateError) return { ok: false, error: updateError.message };

  // Senders under a disabled domain are no longer eligible -- sending_enabled
  // above is what resolveEmailSender() actually gates on; explicitly
  // deactivating them too keeps Settings' own sender list honest without
  // the reader needing to cross-reference domain status.
  await service.from("organization_email_senders").update({ is_active: false }).eq("email_domain_id", domainId);

  await logEmailActivity(organizationId, "email_domain_removed", { domain: domain.domain });
  revalidatePath("/settings/email");
  return { ok: true };
}

export async function setDefaultEmailDomain(domainId: string): Promise<EmailActionResult> {
  const auth = await requireEmailAdmin();
  if ("error" in auth) return { ok: false, error: auth.error };
  const { organizationId } = auth;

  const service = createServiceRoleClient();
  // Gate on sending_enabled, not `status` (spec review item 2) -- see
  // domains.ts's own header comment for why these can diverge.
  const { data: domain } = await service.from("organization_email_domains").select("id, sending_enabled").eq("id", domainId).eq("organization_id", organizationId).maybeSingle();
  if (!domain) return { ok: false, error: "Domain not found." };
  if (!domain.sending_enabled) return { ok: false, error: "This domain is not yet enabled for sending. Check verification before setting it as default." };

  await service.from("organization_email_domains").update({ is_default: false }).eq("organization_id", organizationId);
  const { error } = await service.from("organization_email_domains").update({ is_default: true }).eq("id", domainId);
  if (error) return { ok: false, error: error.message };

  revalidatePath("/settings/email");
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Sender identities (spec section 7). Not a per-address provider object
// (spec section 8) -- purely this app's own row once the domain is
// verified.
// ---------------------------------------------------------------------------
export async function addEmailSender(formData: FormData): Promise<EmailActionResult> {
  const auth = await requireEmailAdmin();
  if ("error" in auth) return { ok: false, error: auth.error };
  const { organizationId, userId } = auth;

  const domainId = String(formData.get("email_domain_id") || "");
  const localPart = String(formData.get("local_part") || "")
    .trim()
    .toLowerCase();
  const displayName = String(formData.get("display_name") || "").trim();
  const replyTo = String(formData.get("reply_to") || "").trim();
  const senderType = String(formData.get("sender_type") || "general");

  if (!displayName) return { ok: false, error: "A display name is required." };
  if (!/^[a-z0-9._%+-]+$/.test(localPart)) return { ok: false, error: "Enter a valid mailbox name (letters, numbers, and . _ % + - only)." };
  if (replyTo && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(replyTo)) return { ok: false, error: "Reply-To must be a valid email address." };
  if (!["billing", "dispatch", "accounting", "general"].includes(senderType)) return { ok: false, error: "Invalid sender type." };

  const service = createServiceRoleClient();
  // Sender addresses must belong to a domain that is GENUINELY eligible
  // to send (spec review item 2: gate on sending_enabled, not `status` --
  // see domains.ts's header comment) -- never an arbitrary address, and
  // never a domain that isn't actually send-capable yet (that would
  // silently produce sends the provider rejects, or worse, sends that
  // quietly fall back without the user realizing why).
  const { data: domain } = await service.from("organization_email_domains").select("id, sending_domain, sending_enabled").eq("id", domainId).eq("organization_id", organizationId).maybeSingle();
  if (!domain) return { ok: false, error: "Domain not found." };
  if (!domain.sending_enabled) return { ok: false, error: "This domain is not yet enabled for sending. Check verification before adding a sender." };

  const emailAddress = `${localPart}@${domain.sending_domain}`;

  const { count } = await service.from("organization_email_senders").select("id", { count: "exact", head: true }).eq("organization_id", organizationId).eq("is_active", true);
  const isFirstSender = (count ?? 0) === 0;

  const { error } = await service.from("organization_email_senders").insert({
    organization_id: organizationId,
    email_domain_id: domainId,
    display_name: displayName,
    email_address: emailAddress,
    reply_to: replyTo || null,
    sender_type: senderType,
    is_default: isFirstSender,
    created_by: userId,
  });
  if (error) {
    if (error.code === "23505") return { ok: false, error: "A sender with this address already exists." };
    return { ok: false, error: error.message };
  }

  await logEmailActivity(organizationId, "email_sender_added", { email_address: emailAddress, sender_type: senderType });
  revalidatePath("/settings/email");
  return { ok: true };
}

export async function updateEmailSender(senderId: string, formData: FormData): Promise<EmailActionResult> {
  const auth = await requireEmailAdmin();
  if ("error" in auth) return { ok: false, error: auth.error };
  const { organizationId } = auth;

  const displayName = String(formData.get("display_name") || "").trim();
  const replyTo = String(formData.get("reply_to") || "").trim();
  const senderType = String(formData.get("sender_type") || "general");
  const isActive = formData.get("is_active") === "1";

  if (!displayName) return { ok: false, error: "A display name is required." };
  if (replyTo && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(replyTo)) return { ok: false, error: "Reply-To must be a valid email address." };
  if (!["billing", "dispatch", "accounting", "general"].includes(senderType)) return { ok: false, error: "Invalid sender type." };

  const service = createServiceRoleClient();
  const { data: sender } = await service.from("organization_email_senders").select("id, is_active, email_domain_id, organization_email_domains(sending_enabled)").eq("id", senderId).eq("organization_id", organizationId).maybeSingle();
  if (!sender) return { ok: false, error: "Sender not found." };

  // Mirrors addEmailSender()'s same guard (spec review item 2: gate on
  // sending_enabled, never `status`) -- found live during Phase 2F
  // post-migration verification: without this, a sender under a disabled
  // domain could be reactivated here with no check at all, since this was
  // the only sender-writing action that didn't independently re-verify
  // domain eligibility before flipping is_active. Only checked when
  // actually ACTIVATING (isActive && not already active) -- editing an
  // already-inactive sender's display name, or explicitly turning it off,
  // is never blocked by this.
  const domain = sender.organization_email_domains as unknown as { sending_enabled: boolean } | null;
  if (isActive && !sender.is_active && !domain?.sending_enabled) {
    return { ok: false, error: "This sender's domain is not currently enabled for sending. Check verification before reactivating it." };
  }

  const { error } = await service.from("organization_email_senders").update({ display_name: displayName, reply_to: replyTo || null, sender_type: senderType, is_active: isActive }).eq("id", senderId);
  if (error) return { ok: false, error: error.message };

  await logEmailActivity(organizationId, "email_sender_changed", { sender_id: senderId });
  revalidatePath("/settings/email");
  return { ok: true };
}

export async function setDefaultEmailSender(senderId: string): Promise<EmailActionResult> {
  const auth = await requireEmailAdmin();
  if ("error" in auth) return { ok: false, error: auth.error };
  const { organizationId } = auth;

  const service = createServiceRoleClient();
  const { data: sender } = await service.from("organization_email_senders").select("id, is_active").eq("id", senderId).eq("organization_id", organizationId).maybeSingle();
  if (!sender) return { ok: false, error: "Sender not found." };
  if (!sender.is_active) return { ok: false, error: "An inactive sender cannot be set as default." };

  await service.from("organization_email_senders").update({ is_default: false }).eq("organization_id", organizationId);
  const { error } = await service.from("organization_email_senders").update({ is_default: true }).eq("id", senderId);
  if (error) return { ok: false, error: error.message };

  revalidatePath("/settings/email");
  return { ok: true };
}
