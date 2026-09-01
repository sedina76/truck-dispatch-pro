// Shared constants + pure helpers for the global Documents library
// (/documents) -- the user-facing status vocabulary, the filter option
// lists, and the expiry-bucket rule. No server-only imports, so the
// client filter bar and the server page can both use it.

// public.document_type enum (0001 + later add-value migrations), in a
// sensible display order. Kept as a flat list rather than read from the DB
// because it is a stable enum and the New/Edit Document forms already
// hard-code the same set.
export const DOCUMENT_TYPE_OPTIONS: { value: string; label: string }[] = [
  { value: "rate_confirmation", label: "Rate Confirmation" },
  { value: "bol", label: "Bill of Lading" },
  { value: "pod", label: "Proof of Delivery" },
  { value: "lumper_receipt", label: "Lumper Receipt" },
  { value: "detention_document", label: "Detention Document" },
  { value: "scale_ticket", label: "Scale Ticket" },
  { value: "cdl", label: "CDL" },
  { value: "medical_card", label: "Medical Card" },
  { value: "insurance_certificate", label: "Certificate of Insurance" },
  { value: "w9", label: "W-9" },
  { value: "motor_carrier_authority", label: "Motor Carrier Authority" },
  { value: "notice_of_assignment", label: "Notice of Assignment" },
  { value: "factoring_notice", label: "Factoring Notice" },
  { value: "voided_check", label: "Voided Check" },
  { value: "signed_agreement", label: "Signed Agreement" },
  { value: "vehicle_registration", label: "Vehicle Registration" },
  { value: "ifta_credential", label: "IFTA Credential" },
  { value: "inspection_report", label: "Inspection Report" },
  { value: "expense_receipt", label: "Expense Receipt" },
  { value: "fuel_receipt", label: "Fuel Receipt" },
  { value: "toll_receipt", label: "Toll Receipt" },
  { value: "repair_invoice", label: "Repair Invoice" },
  { value: "estimate", label: "Estimate" },
  { value: "before_photo", label: "Before Photo" },
  { value: "after_photo", label: "After Photo" },
  { value: "funding_confirmation", label: "Funding Confirmation" },
  { value: "factor_statement", label: "Factor Statement" },
  { value: "chargeback_notice", label: "Chargeback Notice" },
  { value: "other", label: "Other" },
];

export const VERIFICATION_FILTERS = [
  { value: "all", label: "All" },
  { value: "verified", label: "Verified" },
  { value: "unverified", label: "Unverified" },
] as const;

export const EXPIRY_FILTERS = [
  { value: "all", label: "All" },
  { value: "expiring_30", label: "Expiring within 30 days" },
  { value: "expired", label: "Expired" },
  { value: "none", label: "No expiry" },
] as const;

export type DocumentDisplayStatus = "valid" | "unverified" | "expiring_soon" | "expired";

// User-facing status for one document. Deliberately distinct from
// "Missing": every row here IS an uploaded file, so it can never be
// "Missing" (that word is reserved for a required document that does not
// exist -- a compliance-requirement concept, not a documents-row concept).
// An uploaded-but-unconfirmed file reads as "Unverified", not "Missing".
//
// Precedence: a genuinely expired file is the dominant risk signal, then
// an unverified one, then an approaching expiry on an otherwise-good file.
export function computeDocumentStatus(
  expiryDate: string | null,
  isVerified: boolean,
  asOf: Date = new Date()
): DocumentDisplayStatus {
  const today = new Date(asOf.getFullYear(), asOf.getMonth(), asOf.getDate());
  if (expiryDate) {
    const exp = new Date(expiryDate + "T00:00:00");
    if (exp < today) return "expired";
    if (!isVerified) return "unverified";
    const days = (exp.getTime() - today.getTime()) / 86_400_000;
    if (days <= 30) return "expiring_soon";
    return "valid";
  }
  return isVerified ? "valid" : "unverified";
}

export function matchesExpiryFilter(
  filter: string | undefined,
  expiryDate: string | null,
  asOf: Date = new Date()
): boolean {
  if (!filter || filter === "all") return true;
  if (filter === "none") return !expiryDate;
  if (!expiryDate) return false;
  const today = new Date(asOf.getFullYear(), asOf.getMonth(), asOf.getDate());
  const exp = new Date(expiryDate + "T00:00:00");
  if (filter === "expired") return exp < today;
  if (filter === "expiring_30") {
    const days = (exp.getTime() - today.getTime()) / 86_400_000;
    return days >= 0 && days <= 30;
  }
  return true;
}

// Carrier document types offered by the real staff carrier upload workflow
// (carrier-document-actions.ts). EXISTING public.document_type enum values
// only -- nothing invented. Deliberately excludes:
//   w9               -> dedicated W-9 generation/completion workflow (0099)
//   signed_agreement -> dedicated agreement signing workflow (0082/0089),
//                       immutable via guard_finalized_executed_agreement_document()
export const CARRIER_UPLOAD_DOCUMENT_TYPES = [
  "insurance_certificate",
  "motor_carrier_authority",
  "notice_of_assignment",
  "factoring_notice",
  "voided_check",
  "inspection_report",
  "other",
] as const;

// document_type values that can never be legally deleted from the global
// library: a finalized executed agreement is made immutable by
// guard_finalized_executed_agreement_document() (0089, BEFORE UPDATE OR
// DELETE on public.documents), and a registered W-9 document is governed
// by carrier_w9s immutability + its FK. The library hides the Delete
// action for these rather than offering a button the database will
// always reject.
export const DELETE_PROTECTED_DOCUMENT_TYPES = new Set(["signed_agreement", "w9"]);

// ---------------------------------------------------------------------------
// Global "Add Document" workflow router (/documents/new) configuration.
//
// /documents/new does NOT upload file bytes and there is no generic
// cross-entity storage-upload architecture in this codebase. It is a
// ROUTER: pick a record, then get sent to that record's real byte-upload
// workflow -- or told, honestly, that one does not exist yet. It never
// writes a documents row itself (that was the phantom-record defect).
// ---------------------------------------------------------------------------

// The business record types the router offers. Deliberately NOT the full
// public.entity_type enum.
export const NEW_DOCUMENT_ENTITY_TYPES = [
  { value: "carrier", label: "Carrier" },
  { value: "driver", label: "Driver" },
  { value: "load", label: "Load" },
  { value: "broker", label: "Broker" },
  { value: "customer", label: "Customer" },
] as const;

export type NewDocumentEntityType = (typeof NEW_DOCUMENT_ENTITY_TYPES)[number]["value"];

export const NEW_DOCUMENT_ENTITY_TYPE_SET = new Set<string>(
  NEW_DOCUMENT_ENTITY_TYPES.map((e) => e.value)
);

// Per-record-type routing decision. `uploadHref(id)` returns the real
// staff byte-upload workflow when one exists (verified by audit -- see the
// phantom-document repair report), else null. `recordHref(id)` is the
// record's own detail page, always a safe place to send the user.
//   load     -> /loads/[id] renders <UploadDocumentForm> (uploadLoadDocument(),
//               real bytes -> load-documents bucket). REAL.
//   carrier  -> no staff "attach a file to an existing carrier" workflow
//               exists (onboarding portal / W-9 / agreement / setup package
//               are all dedicated flows). NONE.
//   driver   -> no staff driver-record file-upload workflow (driver
//               APPLICATION uploads are a portal/review flow). NONE.
//   broker   -> NONE.
//   customer -> NONE.
export const NEW_DOCUMENT_ROUTING: Record<
  NewDocumentEntityType,
  { uploadHref: ((id: string) => string) | null; recordHref: (id: string) => string; recordLabel: string }
> = {
  load: {
    uploadHref: (id) => `/loads/${id}`,
    recordHref: (id) => `/loads/${id}`,
    recordLabel: "load",
  },
  carrier: {
    // Real staff carrier document upload lives on the carrier's Documents
    // tab (see carrier-document-actions.ts -> uploadCarrierDocument()).
    uploadHref: (id) => `/carriers/${id}?tab=documents`,
    recordHref: (id) => `/carriers/${id}`,
    recordLabel: "carrier",
  },
  driver: {
    uploadHref: null,
    recordHref: (id) => `/drivers/${id}`,
    recordLabel: "driver",
  },
  broker: {
    uploadHref: null,
    recordHref: (id) => `/brokers/${id}`,
    recordLabel: "broker",
  },
  customer: {
    uploadHref: null,
    recordHref: (id) => `/customers/${id}`,
    recordLabel: "customer",
  },
};
