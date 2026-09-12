import "server-only";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import type { FactoringCompanyRow, FactoringRelationshipRow } from "./types";

// ---------------------------------------------------------------------------
// getDefaultFactoringRelationship -- Phase 3B.1.3 rewrite. Factoring
// defaults are CARRIER-scoped (0138's cutover), never organization-wide --
// the pre-3B.1 version of this function (`getDefaultFactoringRelationship
// (organizationId)`) queried is_default+is_active filtered ONLY by
// organization_id, which was safe only while at most one relationship in
// the whole org could ever be the default. Once a second carrier gets its
// own default (0138's carrier-scoped partial unique index permits exactly
// that), that old query could match 2+ rows and either error out via
// .maybeSingle() or -- worse -- silently hand back whichever carrier's
// default the query happened to return, for an invoice belonging to a
// DIFFERENT carrier. This rewrite requires carrierId as its ONLY lookup
// key; no caller may ask "what's the org's default" any more, only "what's
// THIS carrier's default."
//
// Uses the caller's own authenticated session (never service_role) --
// factoring_relationships/factoring_companies RLS (0071) already scopes
// SELECT to the caller's organization + FINANCIAL_ROLES, so there is no
// reason to bypass it for a read for this now-mandatory-carrier-scoped
// helper (Phase 3B.1.3, Section C: don't reach for service_role just
// because it's convenient).
// ---------------------------------------------------------------------------

export type DefaultFactoringRelationshipResult =
  | { status: "ready"; company: FactoringCompanyRow; relationship: FactoringRelationshipRow }
  // No usable default configured for this carrier (none at all, or its
  // only default row's company has gone inactive) -- a normal, expected
  // state for a carrier that hasn't been fully set up yet, never an error.
  | { status: "none" }
  // More than one active+default relationship exists for this SAME
  // carrier -- should be structurally impossible under 0138's
  // factoring_relationships_one_default_per_carrier partial unique index.
  // Surfaced as its own distinct status specifically so no caller can ever
  // paper over data corruption by grabbing an arbitrary row from the set.
  | { status: "integrity_error"; message: string };

export async function getDefaultFactoringRelationship(carrierId: string): Promise<DefaultFactoringRelationshipResult> {
  if (!carrierId) {
    throw new Error("getDefaultFactoringRelationship: carrierId is required -- there is no organization-wide default any more.");
  }

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  // Defense in depth: confirm the carrier actually belongs to this
  // organization before trusting anything derived from carrierId below --
  // RLS on factoring_relationships already enforces this independently
  // (the .eq("organization_id", organizationId) filter below), but a
  // carrier from another org should never even reach the "not found"
  // vs. "wrong org" branch below with an ambiguous message.
  const { data: carrier } = await supabase.from("carriers").select("id").eq("id", carrierId).eq("organization_id", organizationId).maybeSingle();
  if (!carrier) return { status: "none" };

  const { data: relationships, error } = await supabase
    .from("factoring_relationships")
    .select("*")
    .eq("carrier_id", carrierId)
    .eq("organization_id", organizationId)
    .eq("is_default", true)
    .eq("is_active", true);

  if (error) {
    console.error("[factoring] getDefaultFactoringRelationship query failed:", error.message);
    return { status: "none" };
  }
  if (!relationships || relationships.length === 0) return { status: "none" };

  if (relationships.length > 1) {
    console.error(
      `[factoring] INTEGRITY ERROR: carrier ${carrierId} has ${relationships.length} active+default factoring_relationships rows -- factoring_relationships_one_default_per_carrier should make this impossible.`
    );
    return { status: "integrity_error", message: "This carrier has more than one active default factoring relationship. Contact support before submitting an invoice for this carrier." };
  }

  const relationship = relationships[0] as FactoringRelationshipRow;

  const { data: company } = await supabase.from("factoring_companies").select("*").eq("id", relationship.factoring_company_id).eq("organization_id", organizationId).maybeSingle();
  // A default relationship whose company has since gone inactive is not a
  // USABLE default (mirrors classify_carrier_factoring_readiness()'s own
  // factoring_company_inactive gate) -- reported as "none" here, since
  // this helper's only job is "what CAN currently be used," not a full
  // readiness breakdown (callers that need the fuller picture should read
  // classify_carrier_factoring_readiness() directly).
  if (!company || !company.is_active) return { status: "none" };

  // Phase 3B.1.4 fix: effective dates were missing from this check
  // entirely -- a default relationship that is not yet effective, or has
  // already expired, is not a USABLE default either, and
  // submit_invoice_to_factor() (0140) re-verifies this exact window
  // itself. Without this check, this helper could report "ready" for a
  // relationship the submission RPC would then reject, showing a
  // misleading "this invoice can be submitted" state that fails the
  // moment the user actually tries.
  const today = new Date().toISOString().slice(0, 10);
  if (relationship.effective_from > today || (relationship.effective_to !== null && relationship.effective_to < today)) {
    return { status: "none" };
  }

  // No secret_reference or any other credential field exists on either
  // row returned here (factoring_relationships/factoring_companies never
  // had one) -- nothing to strip, but noted explicitly per Phase 3B.1.3
  // Section E's own requirement, since a future column added to either
  // table must not silently start flowing through this helper unreviewed.
  return { status: "ready", company: company as FactoringCompanyRow, relationship };
}
