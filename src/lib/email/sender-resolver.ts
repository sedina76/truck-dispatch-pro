import "server-only";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { PURPOSE_PREFERRED_SENDER_TYPE, isPlatformOnlyPurpose, type EmailPurpose } from "@/lib/email/purposes";

// The ONE place that decides who an email is FROM (spec section 15).
// Nothing else in this app chooses a sender address -- every caller of
// send-pipeline.ts's sendTenantEmail() gets its from/replyTo from here,
// never picks one itself.
export type ResolvedSender = {
  fromName: string;
  fromEmail: string;
  /** "Kali Freights Billing <billing@mail.kalifreights.com>" -- exactly what gets passed to the provider's `from`. */
  fromHeader: string;
  replyTo: string | null;
  senderSource: "platform" | "tenant_verified";
  domainId: string | null;
  senderId: string | null;
  verified: boolean;
};

function platformSender(organizationName: string | null, replyTo: string | null): ResolvedSender {
  const platformFrom = process.env.EMAIL_FROM ?? "";
  const emailMatch = platformFrom.match(/<([^>]+)>/);
  const platformEmail = emailMatch ? emailMatch[1] : platformFrom || "notifications@truckdispatchpro.com";
  // Branded fallback (spec sections 14/53): the tenant's own name stays
  // visible in the From header even though the platform domain is what's
  // actually sending -- "Kali Freights via Truck Dispatch Pro", never a
  // bare, unbranded platform address, and never a spoofed tenant domain.
  const fromName = organizationName ? `${organizationName} via Truck Dispatch Pro` : "Truck Dispatch Pro";
  return {
    fromName,
    fromEmail: platformEmail,
    fromHeader: `${fromName} <${platformEmail}>`,
    replyTo,
    senderSource: "platform",
    domainId: null,
    senderId: null,
    verified: false,
  };
}

/**
 * Resolve who a given organization's email should come FROM for a given
 * purpose. Always returns something sendable -- never throws, never
 * returns null -- because the platform fallback (spec section 14) exists
 * precisely so every organization can send mail from day one, verified
 * domain or not.
 *
 * Platform-only purposes (spec section 54) always take the platform path,
 * regardless of what the organization has configured -- system mail must
 * never accidentally look like it came from a tenant's own domain.
 */
export async function resolveEmailSender({
  organizationId,
  emailPurpose,
}: {
  organizationId: string;
  emailPurpose: EmailPurpose;
}): Promise<ResolvedSender> {
  const service = createServiceRoleClient();
  const { data: org } = await service.from("organizations").select("name, business_email").eq("id", organizationId).maybeSingle();
  const organizationName = org?.name ?? null;
  const orgReplyTo = org?.business_email ?? null;

  if (isPlatformOnlyPurpose(emailPurpose)) {
    return platformSender(organizationName, null);
  }

  // A tenant sender is only eligible when its DOMAIN is genuinely
  // send-capable (spec review item 2) -- gated on sending_enabled
  // (mirrors Resend's own capabilities.sending field), NOT on the overall
  // `status` string. An ambiguous 'partially_verified' domain is used
  // only when the provider has proven the SENDING capability itself is
  // enabled -- see domains.ts's extractSendingEnabled() for the exact
  // rule. This reads the domain row's CURRENT stored value, which
  // checkEmailDomainVerification() keeps in sync with Resend (see
  // settings/email/actions.ts) -- never a stale/inferred approximation.
  // is_active on the sender additionally gates it out if staff have
  // deliberately turned it off.
  const preferredType = PURPOSE_PREFERRED_SENDER_TYPE[emailPurpose];
  const { data: senders } = await service
    .from("organization_email_senders")
    .select("id, display_name, email_address, reply_to, sender_type, is_default, email_domain_id, organization_email_domains(sending_enabled)")
    .eq("organization_id", organizationId)
    .eq("is_active", true);

  const eligible = (senders ?? []).filter((s) => {
    const domain = s.organization_email_domains as unknown as { sending_enabled: boolean } | null;
    return domain?.sending_enabled === true;
  });

  const chosen = (preferredType && eligible.find((s) => s.sender_type === preferredType)) || eligible.find((s) => s.is_default) || eligible[0] || null;

  if (!chosen) {
    return platformSender(organizationName, orgReplyTo);
  }

  return {
    fromName: chosen.display_name,
    fromEmail: chosen.email_address,
    fromHeader: `${chosen.display_name} <${chosen.email_address}>`,
    replyTo: chosen.reply_to || orgReplyTo,
    senderSource: "tenant_verified",
    domainId: chosen.email_domain_id,
    senderId: chosen.id,
    verified: true,
  };
}
