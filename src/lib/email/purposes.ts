// Centralized email-purpose values (spec section 36) -- plain string union
// + a runtime Set, not a Postgres enum (matches email_send_log.entity_type's
// own long-standing precedent of staying plain `text`, see 0039), so a
// future purpose (statement, collections, dispatch_message) never needs an
// `ALTER TYPE ... ADD VALUE` migration. Only purposes an actual current
// workflow produces are listed -- no speculative taxonomy.
export type EmailPurpose =
  | "platform_system" // login/security notices, org invitations, account workflows -- not sent by this phase's pipeline yet, reserved for callers that need it
  | "invoice"
  | "billing_packet"
  | "receipt"
  | "statement"
  | "settlement"
  | "profile_share"
  | "carrier_onboarding_invitation"
  | "carrier_setup_package";

export const EMAIL_PURPOSES: EmailPurpose[] = ["platform_system", "invoice", "billing_packet", "receipt", "statement", "settlement", "profile_share", "carrier_onboarding_invitation", "carrier_setup_package"];

export const EMAIL_PURPOSE_LABEL: Record<EmailPurpose, string> = {
  platform_system: "Platform / System",
  invoice: "Invoice",
  billing_packet: "Billing Packet",
  receipt: "Payment Receipt",
  statement: "Statement",
  settlement: "Settlement",
  profile_share: "Driver/Carrier Profile Share",
  carrier_onboarding_invitation: "Carrier Onboarding Invitation",
  carrier_setup_package: "Carrier Setup Package",
};

export function isEmailPurpose(value: string): value is EmailPurpose {
  return (EMAIL_PURPOSES as string[]).includes(value);
}

// Which purposes are "tenant business email" (spec section 3 -- should use
// the tenant's verified domain when available, fall back to platform
// sender when not) vs "platform email" (spec section 54 -- must NEVER use
// a tenant sender, always the platform domain, regardless of org). Only
// platform_system is platform-only today; every other purpose this phase
// actually sends is tenant business email.
export function isPlatformOnlyPurpose(purpose: EmailPurpose): boolean {
  return purpose === "platform_system";
}

// Which sender_type (organization_email_senders.sender_type) a purpose
// prefers when the org has more than one active sender. Falls back to the
// org's default sender if no sender of this type exists (see
// sender-resolver.ts) -- this is a preference order, not a hard
// requirement, so an org that only ever configures one general sender
// still works for every purpose.
export const PURPOSE_PREFERRED_SENDER_TYPE: Partial<Record<EmailPurpose, string>> = {
  invoice: "billing",
  billing_packet: "billing",
  receipt: "billing",
  statement: "billing",
  settlement: "accounting",
  carrier_setup_package: "dispatch",
};
