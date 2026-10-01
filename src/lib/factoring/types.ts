// Phase 2H.3 -- shared row/label types for the factoring settings
// workspace (companies + relationships master data) and, going forward,
// anything else in Phase 2H that needs to read the same shape. Column
// names match live 0071 schema exactly (confirmed against the applied
// database's PostgREST OpenAPI definitions, not just the migration file).

export type FeeTiming = "deducted_at_funding" | "deducted_from_reserve";
export type RecourseType = "recourse" | "non_recourse";

export const FEE_TIMING_OPTIONS: { value: FeeTiming; label: string; description: string }[] = [
  { value: "deducted_at_funding", label: "Deduct fee at funding", description: "The factoring fee is subtracted from the advance the moment the invoice is funded." },
  { value: "deducted_from_reserve", label: "Deduct fee from reserve", description: "The advance is paid in full; the factoring fee is subtracted later, from the reserve, when it's released." },
];

export const RECOURSE_TYPE_OPTIONS: { value: RecourseType; label: string; description: string }[] = [
  { value: "recourse", label: "Recourse", description: "If the customer fails to pay, your organization may be required to buy the invoice back from the factor." },
  { value: "non_recourse", label: "Non-recourse", description: "The factor assumes defined credit risk for non-payment, subject to the terms of your specific agreement -- not a guarantee against every reason an invoice might go unpaid." },
];

export type FactoringCompanyRow = {
  id: string;
  organization_id: string;
  name: string;
  legal_name: string | null;
  contact_name: string | null;
  email: string | null;
  phone: string | null;
  website: string | null;
  address_line1: string | null;
  city: string | null;
  state: string | null;
  postal_code: string | null;
  account_number: string | null;
  notes: string | null;
  is_active: boolean;
  created_at: string;
};

// Phase 3B.1.3 -- carrier-scoped classifier vocabulary
// (classify_carrier_factoring_readiness(), 0138/0139). One string union so
// every caller that renders a classification (settings UI, invoice page)
// shares the same exhaustive set -- never a bare `string`.
export type CarrierFactoringClassification =
  | "factoring_policy_unconfigured"
  | "direct_billing"
  | "no_factoring_configuration"
  | "no_default"
  | "default_inactive"
  | "default_expired"
  | "default_not_yet_effective"
  | "factoring_company_inactive"
  | "relationship_incomplete"
  | "multiple_defaults"
  | "api_integration_missing"
  | "api_integration_not_ready"
  | "carrier_party_inactive"
  | "carrier_party_ineligible"
  | "carrier_party_direct_billing_exception"
  | "ready"
  | "error";

export type CarrierFactoringReadiness = {
  classification: CarrierFactoringClassification;
  relationshipId: string | null;
  missing: string[] | null;
  message: string | null;
};

export type CarrierFactoringMode = "unconfigured" | "direct" | "factored";

// Carrier option for a relationship's carrier picker/label -- deliberately
// NEVER the full carriers row (no address/contact/financial fields leak
// into a factoring dropdown that has no reason to see them).
export type CarrierOption = {
  id: string;
  legal_name: string;
  is_active: boolean;
  factoring_mode: CarrierFactoringMode | null; // null only when 0136 is not yet applied
};

export type FactoringRelationshipRow = {
  id: string;
  organization_id: string;
  carrier_id: string;
  factoring_company_id: string;
  relationship_name: string | null;
  default_advance_percentage: number;
  default_factoring_fee_percentage: number;
  default_reserve_percentage: number;
  fee_timing: FeeTiming;
  recourse_type: RecourseType;
  payment_terms_days: number | null;
  minimum_fee: number | null;
  wire_fee: number | null;
  ach_fee: number | null;
  other_fee_default: number | null;
  is_default: boolean;
  is_active: boolean;
  effective_from: string;
  effective_to: string | null;
  created_at: string;
  // Carrier-scoped readiness/configuration columns (0136). Optional so this
  // type still describes rows read before 0136 was applied.
  remittance_instructions?: string | null;
  remittance_reference?: string | null;
  noa_approved?: boolean | null;
  noa_reference?: string | null;
  noa_effective_date?: string | null;
  noa_template_text?: string | null;
  noa_document_id?: string | null;
  noa_approved_at?: string | null;
  submission_method?: FactoringSubmissionMethod | null;
  submission_destination_email?: string | null;
  submission_notes?: string | null;
};

// A carrier's verified NOA / factoring-notice document, offered when
// approving a Notice of Assignment.
export type NoaDocumentOption = { id: string; fileName: string; documentType: string; createdAt: string };

// public.factoring_submission_method (0136). "api" additionally requires an
// active factoring API integration (0141) and is configured elsewhere.
export type FactoringSubmissionMethod = "secure_email" | "api" | "portal_manual" | "internal_queue";

export const SUBMISSION_METHOD_OPTIONS: { value: Exclude<FactoringSubmissionMethod, "api">; label: string; description: string }[] = [
  { value: "secure_email", label: "Email to the factor", description: "Invoices are emailed to the factor's submission address." },
  { value: "portal_manual", label: "Factor's web portal (manual upload)", description: "Someone uploads each invoice on the factor's own website." },
  { value: "internal_queue", label: "Internal queue", description: "Invoices are queued here for your team to submit by hand." },
];

// Derived UI-only lifecycle label (spec Phase 2H.3 section 10) -- NEVER a
// stored/DB status. is_active remains the one real enable/disable control;
// this is purely "where does today fall in this row's effective range."
export type EffectiveState = "inactive" | "scheduled" | "active" | "expired";

export function deriveEffectiveState(row: Pick<FactoringRelationshipRow, "is_active" | "effective_from" | "effective_to">, today: string = new Date().toISOString().slice(0, 10)): EffectiveState {
  if (!row.is_active) return "inactive";
  if (row.effective_from && row.effective_from > today) return "scheduled";
  if (row.effective_to && row.effective_to < today) return "expired";
  return "active";
}

export const EFFECTIVE_STATE_LABEL: Record<EffectiveState, string> = {
  inactive: "Inactive",
  scheduled: "Scheduled",
  active: "Active",
  expired: "Expired",
};
