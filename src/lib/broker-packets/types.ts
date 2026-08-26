// Mirrors src/lib/carrier-setup-packages/types.ts's constants deliberately --
// same underlying limits (2M.2B: "Preserve existing setup-package size
// limits unless source inspection proves a different established constant
// is authoritative" -- none did). Kept as a separate module because Broker
// Packet is a distinct business object (see 0095's header comment), not a
// re-export, so the two can diverge later without one silently changing
// the other's behavior.

export const BROKER_PACKET_BUCKET = "broker-packets";
// 2N.2B: broadened from a single BROKER_PACKET_SOURCE_BUCKET string to an
// explicit allowlist, matching 0100_broker_packet_multi_bucket_documents.sql's
// guard_broker_packet_item() allowlist exactly -- a source document may now
// legitimately live in the generic `documents` bucket OR the private
// `carrier-w9s` bucket (0099). The DB trigger is still the authoritative
// enforcement point; this set is this app code's own defense-in-depth
// mirror of it, not a new grant of trust.
export const BROKER_PACKET_SOURCE_BUCKETS = new Set(["documents", "carrier-w9s"]);
export const MAX_PACKET_DOCUMENTS = 12;
export const MAX_SINGLE_SOURCE_BYTES = 10 * 1024 * 1024;
export const MAX_GENERATED_BYTES = 50 * 1024 * 1024;
export const MAX_PACKAGE_PAGES = 250;
// Matches carrier-setup-packages/types.ts's MAX_EMAIL_ATTACHMENT_BYTES
// exactly -- this is Resend's own practical attachment ceiling, not a
// Broker-Packet-specific number, so it's kept identical rather than
// invented independently.
export const MAX_EMAIL_ATTACHMENT_BYTES = 20 * 1024 * 1024;

// Same catalog as carrier setup packages -- the broker-facing document
// categories a carrier profile is built from are the same regardless of
// which audience (broker vs internal onboarding) the packet is for.
export const DEFAULT_DOCUMENT_TYPES = [
  "w9",
  "insurance_certificate",
  "motor_carrier_authority",
  "notice_of_assignment",
  "factoring_notice",
  "voided_check",
] as const;

export const OPTIONAL_DOCUMENT_TYPES = ["other"] as const;

export const DOCUMENT_LABELS: Record<string, string> = {
  w9: "W-9",
  insurance_certificate: "Certificate of Insurance",
  motor_carrier_authority: "Operating Authority",
  notice_of_assignment: "Notice of Assignment",
  factoring_notice: "Factoring Notice",
  voided_check: "Voided Check",
  other: "Additional Document",
};

// Frozen at reserve_broker_packet() (0096 repair) -- see that migration's
// jsonb_build_object() calls for the authoritative key list. Never rebuild
// packet identity from live organization/broker/carrier tables once a
// packet has reserved; the renderer must consume exactly these shapes.
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

export type BrokerSnapshot = {
  legal_name: string;
  dba_name?: string;
  mc_number?: string;
  dot_number?: string;
};

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
};

export type BrokerPacketRow = {
  id: string;
  organization_id: string;
  broker_id: string;
  carrier_id: string | null;
  version: number | null;
  status: "draft" | "generating" | "generated" | "sent" | "superseded" | "failed" | "voided";
  document_count: number;
  organization_snapshot: OrganizationSnapshot | null;
  broker_snapshot: BrokerSnapshot | null;
  carrier_snapshot: CarrierSnapshot | null;
  generated_storage_path: string | null;
  generated_file_size_bytes: number | null;
  generated_pdf_sha256: string | null;
  page_count: number | null;
  generated_at: string | null;
  failure_reason: string | null;
  void_reason: string | null;
  created_at: string;
};

export type BrokerPacketItemRow = {
  id: string;
  document_id: string;
  document_type: string;
  display_order: number;
  source_filename: string;
  source_storage_bucket: string;
  source_storage_path: string;
  source_mime_type: string | null;
  source_file_size_bytes: number | null;
  source_expiry_date: string | null;
};

export function brokerPacketStoragePath(pkg: Pick<BrokerPacketRow, "organization_id" | "broker_id" | "id" | "version">) {
  return `${pkg.organization_id}/${pkg.broker_id}/${pkg.id}/broker-packet-v${pkg.version}.pdf`;
}
