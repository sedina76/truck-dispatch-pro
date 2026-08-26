import "server-only";
import { createClient } from "@/lib/supabase/server";
import { DEFAULT_DOCUMENT_TYPES, DOCUMENT_LABELS, MAX_SINGLE_SOURCE_BYTES, OPTIONAL_DOCUMENT_TYPES } from "./types";

export type BrokerPacketCandidate = {
  documentId: string | null;
  documentType: string;
  label: string;
  fileName: string | null;
  status: "eligible" | "missing" | "unverified" | "rejected" | "expired" | "unsupported" | "too_large" | "unlinked";
  statusMessage: string;
};

type DocumentRow = {
  id: string;
  entity_type: string;
  entity_id: string;
  document_type: string;
  file_name: string;
  mime_type: string | null;
  file_size_bytes: number | null;
  expiry_date: string | null;
  is_verified: boolean;
  verified_at: string | null;
  rejected_at: string | null;
};

// Phase 2M.2A repair -- audited root cause of "every document shows
// MISSING": this function only ever looked at entity_type IN
// ('broker','carrier'). Two real gaps found, both fixed below without any
// migration/backfill (Section P: a schema-level asymmetry WAS found --
// see the carrier_onboarding_application relationship below -- but the
// fix here is read-side only, never rewriting a row):
//
// 1. convert_carrier_onboarding_application() (0099) re-points ONLY the
//    W-9's registered document onto the new carrier at conversion time --
//    insurance_certificate/motor_carrier_authority/notice_of_assignment/
//    factoring_notice/voided_check/other uploaded during onboarding stay
//    filed under entity_type='carrier_onboarding_application' and the
//    OLD application id forever. A real, fully-documented, converted
//    carrier's documents were therefore invisible to this function for
//    every type except W-9. Fixed by ALSO checking the originating
//    application (found via carrier_onboarding_applications.
//    converted_carrier_id) when a carrier is selected -- read-only,
//    moves no bytes, changes no row.
// 2. A packet with no carrier selected represents (per packets/new/
//    page.tsx's own copy) "this organization's own operating profile" --
//    entity_type='organization' is schema-eligible (0095's guard already
//    allows it) but was never checked here. Now included for the
//    no-carrier case.
//
// Certificate of Insurance additionally consults the dedicated
// insurance_policies table (0014) -- carrier_id null there means "the
// dispatch company's own policy", set means "a carrier's policy on
// file", exactly mirroring the no-carrier/has-carrier split above. See
// resolveInsuranceCertificate() below for exactly how "current" is
// chosen. NOTE (Section F gap, reported, not silently worked around):
// insurance_policies.document_id is a real column but no UI anywhere in
// this app currently sets it (audited: neither createInsurancePolicy()/
// updateInsurancePolicy() nor the policy detail page ever writes it) --
// so this path only activates once a policy actually has one, which may
// be never yet in a given organization's real data today.
export async function listBrokerPacketCandidates(brokerId: string, carrierId: string | null): Promise<BrokerPacketCandidate[]> {
  const supabase = await createClient();
  const { data: broker } = await supabase.from("brokers").select("organization_id").eq("id", brokerId).maybeSingle();
  if (!broker) return [];
  const organizationId = broker.organization_id;

  const relationships: { entity_type: string; entity_id: string }[] = [{ entity_type: "broker", entity_id: brokerId }];
  if (carrierId) {
    relationships.push({ entity_type: "carrier", entity_id: carrierId });
    const { data: originatingApp } = await supabase
      .from("carrier_onboarding_applications")
      .select("id")
      .eq("converted_carrier_id", carrierId)
      .maybeSingle();
    if (originatingApp) relationships.push({ entity_type: "carrier_onboarding_application", entity_id: originatingApp.id });
  } else {
    relationships.push({ entity_type: "organization", entity_id: organizationId });
  }

  // Paired (entity_type, entity_id) conditions via .or(), not two
  // independent .in() filters -- the previous version's .in()/.in() pair
  // was a latent cross-match bug (harmless in practice against real UUIDs,
  // but not what it looked like it meant). relationships is entirely
  // server-derived (fixed literal entity_type strings, UUIDs from our own
  // prior queries), never raw user input, so building the .or() string
  // directly from it is safe.
  const orFilter = relationships.map((r) => `and(entity_type.eq.${r.entity_type},entity_id.eq.${r.entity_id})`).join(",");
  const { data } = await supabase
    .from("documents")
    .select("id, entity_type, entity_id, document_type, file_name, mime_type, file_size_bytes, expiry_date, is_verified, verified_at, rejected_at")
    .or(orFilter)
    .order("created_at", { ascending: false })
    .order("id", { ascending: false });

  const latest = new Map<string, DocumentRow>();
  for (const document of (data ?? []) as DocumentRow[]) {
    const key = `${document.entity_type}:${document.entity_id}:${document.document_type}`;
    if (!latest.has(key)) latest.set(key, document);
  }

  function classify(document: DocumentRow): { status: BrokerPacketCandidate["status"]; message: string } {
    if (document.rejected_at) return { status: "rejected", message: "The current document was rejected." };
    if (!document.is_verified || !document.verified_at) return { status: "unverified", message: "Verification is required before inclusion." };
    if (document.expiry_date && document.expiry_date < new Date().toISOString().slice(0, 10)) return { status: "expired", message: "This document is expired." };
    if (!["application/pdf", "image/jpeg", "image/png"].includes(document.mime_type ?? "")) return { status: "unsupported", message: "Only PDF, JPG, and PNG documents can be included." };
    if (!document.file_size_bytes || document.file_size_bytes > MAX_SINGLE_SOURCE_BYTES) return { status: "too_large", message: "The source must have a known size of 10 MB or less." };
    return { status: "eligible", message: "Verified and current" };
  }

  const documentTypes = [...DEFAULT_DOCUMENT_TYPES, ...OPTIONAL_DOCUMENT_TYPES];
  const candidates: BrokerPacketCandidate[] = [];
  const insuranceCertificate = await resolveInsuranceCertificate(supabase, organizationId, carrierId);

  for (const documentType of documentTypes) {
    if (documentType === "insurance_certificate" && insuranceCertificate) {
      candidates.push(insuranceCertificate);
      continue;
    }
    let foundAny = false;
    for (const rel of relationships) {
      const document = latest.get(`${rel.entity_type}:${rel.entity_id}:${documentType}`);
      if (!document) continue;
      foundAny = true;
      // guard_broker_packet_item() (0095) only accepts entity_type IN
      // ('broker', 'carrier', 'organization') -- 'carrier_onboarding_
      // application' is NOT in that allow-list, so a document found only
      // via that relationship can be surfaced (the org DOES have it on
      // file -- never claim "missing" here) but must never be offered as
      // directly addable, or "Add to packet" would fail against the DB
      // guard. Reported as a genuine gap (2M.2A report Section 30): fully
      // resolving this needs either extending that guard's allow-list or
      // a backfill re-pointing these documents onto the carrier the same
      // way 0099 already does for W-9 alone -- both are migrations, not
      // shipped here per the standing "STOP before creating a migration"
      // rule.
      if (rel.entity_type === "carrier_onboarding_application") {
        candidates.push({
          documentId: document.id,
          documentType,
          label: `${DOCUMENT_LABELS[documentType] ?? documentType} (from onboarding)`,
          fileName: document.file_name,
          status: "unlinked",
          statusMessage: "On file from this carrier's original onboarding application, but not yet linked to the carrier record -- contact support to link it before it can be added to a packet.",
        });
        continue;
      }
      const { status, message } = classify(document);
      candidates.push({ documentId: document.id, documentType, label: `${DOCUMENT_LABELS[documentType] ?? documentType} (${rel.entity_type.replace("_", " ")})`, fileName: document.file_name, status, statusMessage: message });
    }
    if (!foundAny) {
      candidates.push({ documentId: null, documentType, label: DOCUMENT_LABELS[documentType] ?? documentType, fileName: null, status: "missing", statusMessage: "No current document on file." });
    }
  }
  return candidates;
}

// Certificate of Insurance: prefers the structured insurance_policies
// table (0014) over a same-typed generic `documents` row, since it's the
// more authoritative, compliance-tracked source when populated. "Current"
// = the policy (for the correct subject -- carrier_id = carrierId, or
// carrier_id IS NULL for the organization's own policy when no carrier is
// selected) with a non-null document_id, preferring policy_type =
// 'general_liability' (the policy a COI is conventionally built around),
// otherwise the one with the latest expiry_date -- mirrors
// src/app/(app)/compliance/insurance/page.tsx's own expiry ordering
// convention (nulls last) rather than inventing a new one. Returns null
// (not "missing") when no policy has ever had a document attached, so the
// caller falls back to a same-typed generic `documents` row instead.
async function resolveInsuranceCertificate(
  supabase: Awaited<ReturnType<typeof createClient>>,
  organizationId: string,
  carrierId: string | null
): Promise<BrokerPacketCandidate | null> {
  // Supabase-js has no single-call "carrier_id = X OR carrier_id IS NULL"
  // toggle by variable -- issue the correct filter explicitly for whichever
  // subject this packet actually represents, one query either way.
  const { data: subjectPolicies } = carrierId
    ? await supabase.from("insurance_policies").select("id, policy_type, document_id, expiry_date").eq("organization_id", organizationId).eq("carrier_id", carrierId).not("document_id", "is", null)
    : await supabase.from("insurance_policies").select("id, policy_type, document_id, expiry_date").eq("organization_id", organizationId).is("carrier_id", null).not("document_id", "is", null);

  const rows = subjectPolicies ?? [];
  if (rows.length === 0) return null;

  const gl = rows.find((r) => r.policy_type === "general_liability");
  const chosen = gl ?? [...rows].sort((a, b) => (b.expiry_date ?? "").localeCompare(a.expiry_date ?? ""))[0];
  if (!chosen?.document_id) return null;

  const { data: document } = await supabase
    .from("documents")
    .select("id, entity_type, entity_id, document_type, file_name, mime_type, file_size_bytes, expiry_date, is_verified, verified_at, rejected_at")
    .eq("id", chosen.document_id)
    .maybeSingle();
  if (!document) return null;

  const effectiveExpiry = chosen.expiry_date ?? document.expiry_date;
  let status: BrokerPacketCandidate["status"] = "eligible";
  let message = "Verified and current";
  // Same guard-allow-list safety check as the main loop above -- this
  // path is currently dead in practice (document_id is never set by any
  // existing UI, see this function's header comment), but kept correct
  // in case that changes.
  if (!["broker", "carrier", "organization"].includes(document.entity_type)) [status, message] = ["unlinked", "On file, but not yet linked to a broker, carrier, or organization record that a packet can source from."];
  else if (document.rejected_at) [status, message] = ["rejected", "The current document was rejected."];
  else if (!document.is_verified || !document.verified_at) [status, message] = ["unverified", "Verification is required before inclusion."];
  else if (effectiveExpiry && effectiveExpiry < new Date().toISOString().slice(0, 10)) [status, message] = ["expired", "This policy has expired."];
  else if (!["application/pdf", "image/jpeg", "image/png"].includes(document.mime_type ?? "")) [status, message] = ["unsupported", "Only PDF, JPG, and PNG documents can be included."];
  else if (!document.file_size_bytes || document.file_size_bytes > MAX_SINGLE_SOURCE_BYTES) [status, message] = ["too_large", "The source must have a known size of 10 MB or less."];

  return {
    documentId: document.id,
    documentType: "insurance_certificate",
    label: `${DOCUMENT_LABELS.insurance_certificate} (${carrierId ? "carrier policy" : "company policy"})`,
    fileName: document.file_name,
    status,
    statusMessage: message,
  };
}
