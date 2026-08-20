import "server-only";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import type { FactoringCompanyRow, FactoringRelationshipRow } from "./types";

export type DefaultFactoringRelationship = {
  company: FactoringCompanyRow;
  relationship: FactoringRelationshipRow;
};

// ---------------------------------------------------------------------------
// getDefaultFactoringRelationship -- Phase 2H.3's reusable answer to the
// question Phase 2H.4 will actually need to ask: "what factoring
// relationship (and terms) should THIS invoice use if the user doesn't
// pick one explicitly?" Reads the same is_default+is_active partial unique
// index (factoring_relationships_one_default_per_org, 0071) that
// guarantees at most one row can ever match -- .maybeSingle() below can
// therefore never legitimately see more than one row; if it somehow did,
// that would indicate index/constraint corruption, not a normal state
// this helper needs to disambiguate.
//
// Returns null (never throws) when the org has no USABLE default -- either
// none configured at all, or (Phase 2H.3A) its default relationship's
// company has since gone inactive. As of 0072,
// guard_factoring_company_deactivation() makes the latter unreachable
// going forward (a company can no longer be deactivated while it owns the
// current active default), but this helper filters on company.is_active
// = true anyway rather than trusting that invariant blindly -- a
// defensive read rule, not a substitute for it: a org that predates 0072,
// or a future schema change that relaxes the trigger, must never cause
// Phase 2H.4 to hand back an inactive factor as "the" default. Deliberately
// does NOT create/submit anything -- read-only, no write to
// factored_invoices or any other table (Phase 2H.4's job).
// ---------------------------------------------------------------------------
export async function getDefaultFactoringRelationship(organizationId: string): Promise<DefaultFactoringRelationship | null> {
  const supabase = createServiceRoleClient();

  const { data: relationship } = await supabase
    .from("factoring_relationships")
    .select("*")
    .eq("organization_id", organizationId)
    .eq("is_default", true)
    .eq("is_active", true)
    .maybeSingle();
  if (!relationship) return null;

  const { data: company } = await supabase
    .from("factoring_companies")
    .select("*")
    .eq("id", relationship.factoring_company_id)
    .eq("organization_id", organizationId)
    .eq("is_active", true)
    .maybeSingle();
  if (!company) return null; // no active company -- either cross-org corruption (unreachable, see guard_factoring_relationship_org()) or an inactive company (the defensive case this filter exists for)

  return { company: company as FactoringCompanyRow, relationship: relationship as FactoringRelationshipRow };
}
