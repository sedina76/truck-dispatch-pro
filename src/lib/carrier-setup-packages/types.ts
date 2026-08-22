export const SETUP_PACKAGE_SOURCE_BUCKET = "carrier-onboarding-documents";
export const SETUP_PACKAGE_BUCKET = "carrier-setup-packages";
export const MAX_SOURCE_DOCUMENTS = 12;
export const MAX_SOURCE_BYTES = 40 * 1024 * 1024;
export const MAX_SINGLE_SOURCE_BYTES = 10 * 1024 * 1024;
export const MAX_GENERATED_BYTES = 50 * 1024 * 1024;
export const MAX_PACKAGE_PAGES = 250;
export const MAX_EMAIL_ATTACHMENT_BYTES = 20 * 1024 * 1024;

export type CarrierSnapshot = {
  legal_name: string;
  dba_name?: string;
  mc_number?: string;
  dot_number?: string;
  contact_name?: string;
  phone?: string;
  email?: string;
  address?: string;
  factoring_company_name?: string;
  compliance?: { document_type: string; expiry_date?: string; verified_at?: string }[];
};

export type OrganizationSnapshot = {
  name: string;
  dba_name?: string;
  mc_number?: string;
  dot_number?: string;
  phone?: string;
  email?: string;
  address?: string;
  logo_url?: string;
};

export type EquipmentSnapshot = {
  equipment_type?: string;
  truck_count?: number;
  trailer_count?: number;
  trailer_types?: string[];
  preferred_freight?: string;
  operating_regions?: string[];
};

export type SetupPackageItemRow = {
  id: string;
  document_id: string;
  document_type: string;
  display_order: number;
  source_filename: string;
  source_storage_bucket: string;
  source_storage_path: string;
  source_mime_type: string | null;
  source_file_size_bytes: number | null;
  source_created_at: string;
  source_expiry_date: string | null;
  source_verified_at: string;
};

export type SetupPackageRow = {
  id: string;
  organization_id: string;
  onboarding_application_id: string;
  carrier_id: string | null;
  broker_id: string | null;
  version: number;
  status: "generating" | "generated" | "sent" | "failed" | "voided";
  recipient_name: string | null;
  recipient_email: string | null;
  prepared_for_name: string | null;
  carrier_snapshot: CarrierSnapshot;
  organization_snapshot: OrganizationSnapshot;
  equipment_snapshot: EquipmentSnapshot | null;
  generated_storage_path: string | null;
  generated_file_size_bytes: number | null;
  page_count: number | null;
  document_count: number;
  generated_at: string | null;
  last_sent_at: string | null;
  last_sent_recipient_name: string | null;
  last_sent_recipient_email: string | null;
  void_reason: string | null;
  created_at: string;
};

export const DOCUMENT_LABELS: Record<string, string> = {
  w9: "W-9",
  insurance_certificate: "Certificate of Insurance",
  motor_carrier_authority: "Operating Authority",
  notice_of_assignment: "Notice of Assignment",
  factoring_notice: "Factoring Notice",
  voided_check: "Voided Check",
  signed_agreement: "Signed Dispatch Agreement",
  other: "Additional Compliance Document",
};

export const DEFAULT_DOCUMENT_TYPES = [
  "w9",
  "insurance_certificate",
  "motor_carrier_authority",
  "notice_of_assignment",
  "factoring_notice",
  "voided_check",
] as const;

export function setupPackageStoragePath(pkg: Pick<SetupPackageRow, "organization_id" | "onboarding_application_id" | "id" | "version">) {
  return `${pkg.organization_id}/${pkg.onboarding_application_id}/${pkg.id}/carrier-setup-package-v${pkg.version}.pdf`;
}
