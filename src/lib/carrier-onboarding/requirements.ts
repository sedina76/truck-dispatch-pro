import "server-only";

// Phase 2L.4 -- the document checklist an org sees is driven entirely by
// carrier_onboarding_requirements (0081), which is fully org-configurable
// but ships with ZERO seeded rows. Rather than leaving a brand-new org's
// checklist genuinely empty (which would make the "usable Carrier Packet"
// this phase exists to deliver look broken on day one), an org with no
// configured rows falls back to this fixed default list -- purely an
// application-layer fallback, never written to the database. The moment
// an org adds even one row of its own, that org's own configuration
// takes over completely (see getEffectiveOnboardingRequirements below).

export type RequirementItem = {
  documentType: string;
  label: string;
  requirement: "required" | "optional";
  requiresExpiryDate: boolean;
  instructions: string | null;
};

export const DOCUMENT_TYPE_LABEL: Record<string, string> = {
  w9: "W-9",
  insurance_certificate: "Certificate of Insurance",
  motor_carrier_authority: "Operating Authority",
  voided_check: "Voided Check",
  cdl: "Driver/Owner ID",
  other: "Other",
};

const DEFAULT_REQUIREMENTS: RequirementItem[] = [
  { documentType: "w9", label: "W-9", requirement: "required", requiresExpiryDate: false, instructions: null },
  { documentType: "insurance_certificate", label: "Certificate of Insurance", requirement: "required", requiresExpiryDate: true, instructions: null },
  { documentType: "motor_carrier_authority", label: "Operating Authority", requirement: "required", requiresExpiryDate: false, instructions: null },
  { documentType: "voided_check", label: "Voided Check", requirement: "required", requiresExpiryDate: false, instructions: null },
  { documentType: "other", label: "Other", requirement: "optional", requiresExpiryDate: false, instructions: null },
];

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function getEffectiveOnboardingRequirements(supabase: any, organizationId: string): Promise<RequirementItem[]> {
  const { data } = await supabase
    .from("carrier_onboarding_requirements")
    .select("document_type, requirement, display_order, custom_label, instructions, requires_expiry_date, is_active")
    .eq("organization_id", organizationId)
    .eq("is_active", true)
    .order("display_order");

  const rows = (data ?? []) as {
    document_type: string;
    requirement: "required" | "optional" | "excluded";
    custom_label: string | null;
    instructions: string | null;
    requires_expiry_date: boolean;
  }[];

  if (rows.length === 0) return DEFAULT_REQUIREMENTS;

  return rows
    .filter((r) => r.requirement !== "excluded")
    .map((r) => ({
      documentType: r.document_type,
      label: r.custom_label ?? DOCUMENT_TYPE_LABEL[r.document_type] ?? r.document_type,
      requirement: r.requirement as "required" | "optional",
      requiresExpiryDate: r.requires_expiry_date,
      instructions: r.instructions,
    }));
}
