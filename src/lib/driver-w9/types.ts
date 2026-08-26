// Phase 2Q.2B -- Driver W-9. Reuses everything from carrier-w9/types.ts
// that is genuinely subject-independent (the IRS form's own vocabulary:
// tax classification labels, TIN type/format, masking) rather than
// duplicating it -- only the row shape and the few constants that
// actually differ per subject (table/bucket/column list) get their own
// definitions here. driver_w9s is its own table (never the carrier's own
// W-9 -- see that table's migration comment), but the FORM itself is the
// same IRS document either way.
import type { W9TaxClassification, W9TinType, W9Status } from "@/lib/carrier-w9/types";
export { TAX_CLASSIFICATION_LABELS, isValidTinFormat, maskedTin, type W9TaxClassification, type W9TinType } from "@/lib/carrier-w9/types";

export const DRIVER_W9_BUCKET = "driver-w9s";
export const MAX_GENERATED_BYTES = 5242880; // 5 MB, matches the DB CHECK constraint (0109) and the smaller bucket limit (a one-page filled form, no carrier-scale attachments expected)

// Row shape matching the live 0109 authenticated column grant list
// exactly (tin_encrypted is deliberately absent -- never selectable).
export type DriverW9Row = {
  id: string;
  organization_id: string;
  application_id: string | null;
  driver_id: string | null;
  carrier_id: string | null;
  version: number | null;
  status: W9Status;
  form_revision: string;

  name_on_tax_return: string | null;
  business_name: string | null;
  tax_classification: W9TaxClassification | null;
  llc_classification: "C" | "S" | "P" | null;
  other_classification_description: string | null;
  has_foreign_partners_owners: boolean;
  exempt_payee_code: string | null;
  fatca_exemption_code: string | null;

  address_line1: string | null;
  city: string | null;
  state: string | null;
  postal_code: string | null;
  requester_name_address: string | null;
  account_numbers: string | null;

  tin_type: W9TinType | null;
  tin_last4: string | null;

  certified_name: string | null;
  certified_title: string | null;
  certified_at: string | null;
  certification_version: string;

  generated_storage_path: string | null;
  generated_pdf_sha256: string | null;
  generated_file_size_bytes: number | null;
  page_count: number | null;
  generated_at: string | null;
  generated_by: string | null;

  superseded_by: string | null;
  superseded_at: string | null;
  voided_at: string | null;
  voided_by: string | null;
  void_reason: string | null;
  failure_reason: string | null;

  created_at: string;
  updated_at: string;
  created_by: string | null;
};

// Same "authenticated select must use an explicit safe column list, never
// select('*')" rule as W9_STAFF_SAFE_COLUMNS (carrier-w9/types.ts's own
// header comment explains why: tin_encrypted's column-level grant makes a
// bare select('*') fail outright, not degrade).
export const DRIVER_W9_STAFF_SAFE_COLUMNS = [
  "id", "organization_id", "application_id", "driver_id", "carrier_id", "version", "status", "form_revision",
  "name_on_tax_return", "business_name", "tax_classification", "llc_classification", "other_classification_description",
  "has_foreign_partners_owners", "exempt_payee_code", "fatca_exemption_code",
  "address_line1", "city", "state", "postal_code", "requester_name_address", "account_numbers",
  "tin_type", "tin_last4",
  "certified_name", "certified_title", "certified_at", "certification_version",
  "generated_storage_path", "generated_pdf_sha256", "generated_file_size_bytes", "page_count", "generated_at", "generated_by",
  "superseded_by", "superseded_at", "voided_at", "voided_by", "void_reason", "failure_reason",
  "created_at", "updated_at", "created_by",
] as const satisfies readonly (keyof DriverW9Row)[];

export const DRIVER_W9_STAFF_SAFE_SELECT = DRIVER_W9_STAFF_SAFE_COLUMNS.join(", ");

export function driverW9StoragePath(w9: Pick<DriverW9Row, "organization_id" | "id" | "version">) {
  return `${w9.organization_id}/${w9.id}/w9-v${w9.version}.pdf`;
}

// Business rule (2Q.2B Section I): W-9 is required for 1099-style workers
// only, never a W-2 company driver. Kept as one named function so the
// rule is defined exactly once -- the onboarding portal (whether to show/
// require the step), the submission gate, and the staff review card all
// call this instead of each re-deriving the same worker_type check.
export type DriverWorkerType = "company_driver" | "independent_contractor" | "owner_operator";
export function workerTypeRequiresW9(workerType: DriverWorkerType | null): boolean {
  return workerType === "independent_contractor" || workerType === "owner_operator";
}

export const WORKER_TYPE_LABELS: Record<DriverWorkerType, string> = {
  company_driver: "Company Driver (W-2 Employee)",
  independent_contractor: "Independent Contractor (1099)",
  owner_operator: "Owner-Operator (1099)",
};
