// Phase 2N.2 -- Carrier W-9. Mirrors the naming/constant conventions of
// src/lib/broker-packets/types.ts and src/lib/carrier-setup-packages/types.ts
// deliberately, as its own independent module (not a shared import) --
// same reasoning as those two: a distinct business object should be free
// to diverge later without silently changing another feature's behavior.

export const W9_BUCKET = "carrier-w9s";
export const MAX_GENERATED_BYTES = 52428800; // 50 MB, matches the DB CHECK constraint (0099)
export const CURRENT_FORM_REVISION = "2024-03"; // IRS Form W-9, Rev. March 2024 -- reconfirmed live against irs.gov immediately before Phase 2N.2

export type W9Status = "draft" | "completed" | "superseded" | "voided" | "failed";

export type W9TaxClassification =
  | "individual_sole_proprietor"
  | "c_corporation"
  | "s_corporation"
  | "partnership"
  | "trust_estate"
  | "llc"
  | "other";

export const TAX_CLASSIFICATION_LABELS: Record<W9TaxClassification, string> = {
  individual_sole_proprietor: "Individual/sole proprietor",
  c_corporation: "C corporation",
  s_corporation: "S corporation",
  partnership: "Partnership",
  trust_estate: "Trust/estate",
  llc: "Limited liability company",
  other: "Other",
};

export type W9TinType = "ssn" | "ein";

// Row shape matching the live 0099 column grant list exactly
// (tin_encrypted is deliberately absent -- it is never selectable).
export type CarrierW9Row = {
  id: string;
  organization_id: string;
  onboarding_application_id: string | null;
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

  registered_document_id: string | null;
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

// Phase 2P.3A hotfix -- the authenticated `carrier_w9s` SELECT grant (0099
// lines 400-411) is deliberately column-restricted, excluding
// tin_encrypted. PostgreSQL requires SELECT on every column of a table for
// a bare `select("*")` to succeed, so any authenticated (non-service-role)
// read using select("*") against this table fails outright with
// "permission denied for table carrier_w9s" -- it does not degrade to a
// partial row, and supabase-js does not throw, so an uninspected `{ data }`
// destructure silently looks like "no row found" instead of "the query
// itself failed". Every authenticated read of this table must select this
// exact column list (or a subset of it) -- mirrors CarrierW9Row exactly,
// intentionally never including tin_encrypted. Service-role reads (which
// bypass grants entirely -- see src/app/carrier-onboarding/actions.ts) are
// unaffected either way and may continue using select("*") if desired, but
// using this same safe list there too costs nothing and avoids having two
// different query shapes for the same table.
export const W9_STAFF_SAFE_COLUMNS = [
  "id", "organization_id", "onboarding_application_id", "carrier_id", "version", "status", "form_revision",
  "name_on_tax_return", "business_name", "tax_classification", "llc_classification", "other_classification_description",
  "has_foreign_partners_owners", "exempt_payee_code", "fatca_exemption_code",
  "address_line1", "city", "state", "postal_code", "requester_name_address", "account_numbers",
  "tin_type", "tin_last4",
  "certified_name", "certified_title", "certified_at", "certification_version",
  "generated_storage_path", "generated_pdf_sha256", "generated_file_size_bytes", "page_count", "generated_at", "generated_by",
  "registered_document_id", "superseded_by", "superseded_at", "voided_at", "voided_by", "void_reason", "failure_reason",
  "created_at", "updated_at", "created_by",
] as const satisfies readonly (keyof CarrierW9Row)[];

export const W9_STAFF_SAFE_SELECT = W9_STAFF_SAFE_COLUMNS.join(", ");

export function w9StoragePath(w9: Pick<CarrierW9Row, "organization_id" | "id" | "version">) {
  return `${w9.organization_id}/${w9.id}/w9-v${w9.version}.pdf`;
}

// Formatting-only validation (never identity/IRS-matching verification --
// see 0099's set_carrier_w9_tin(), which enforces the authoritative
// 9-digit rule server-side regardless of what this returns).
export function isValidTinFormat(raw: string): boolean {
  return raw.replace(/[^0-9]/g, "").length === 9;
}

export function maskedTin(tinType: W9TinType | null, last4: string | null): string {
  if (!last4) return "--";
  return tinType === "ein" ? `XX-XXX${last4}` : `XXX-XX-${last4}`;
}
