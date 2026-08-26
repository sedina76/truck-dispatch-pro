"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

type ActionResult<T = undefined> = T extends undefined ? { ok: true } | { ok: false; error: string } : { ok: true; data: T } | { ok: false; error: string };

// Phase 2P.3 -- Carrier Compliance UI actions. Every mutation here goes
// through the exact 0102 RPCs (suspend_carrier/lift_carrier_suspension/
// create_compliance_override/revoke_compliance_override) -- this file adds
// no new business logic, no new authorization decision, and no new table
// write. Role/reason/relationship validation all happens inside those
// SECURITY DEFINER functions; nothing here is a substitute for that.

export async function suspendCarrierAction(carrierId: string, reason: string): Promise<ActionResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("suspend_carrier", { p_carrier_id: carrierId, p_reason: reason });
  if (error) return { ok: false, error: error.message };
  revalidatePath(`/carriers/${carrierId}`);
  return { ok: true };
}

export async function liftCarrierSuspensionAction(carrierId: string, reason: string): Promise<ActionResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("lift_carrier_suspension", { p_carrier_id: carrierId, p_reason: reason || null });
  if (error) return { ok: false, error: error.message };
  revalidatePath(`/carriers/${carrierId}`);
  return { ok: true };
}

// Resolves the exact requirement_definition_id that carrier_dispatch_readiness()
// itself would resolve for this key -- same precedence (organization-specific
// row wins over the system row for the same key), same entity_type filter,
// same is_active filter. This does not recompute readiness/status; it only
// identifies which row a carrier-wide override should attach to. RLS already
// restricts the read to this organization's own rows plus system (null) rows.
async function resolveRequirementDefinitionId(
  supabase: Awaited<ReturnType<typeof createClient>>,
  requirementKey: string
): Promise<{ id: string } | { error: string }> {
  const { data, error } = await supabase
    .from("compliance_requirement_definitions")
    .select("id, organization_id")
    .eq("entity_type", "carrier")
    .eq("requirement_key", requirementKey)
    .eq("is_active", true);
  if (error) return { error: error.message };
  const rows = data ?? [];
  const winner = rows.find((r) => r.organization_id !== null) ?? rows[0];
  if (!winner) return { error: "This requirement could not be found." };
  return { id: winner.id };
}

export async function createCarrierComplianceOverrideAction(
  carrierId: string,
  requirementKey: string,
  reason: string,
  expiresAt: string | null
): Promise<ActionResult> {
  const supabase = await createClient();
  const resolved = await resolveRequirementDefinitionId(supabase, requirementKey);
  if ("error" in resolved) return { ok: false, error: resolved.error };

  const { error } = await supabase.rpc("create_compliance_override", {
    p_carrier_id: carrierId,
    p_reason: reason,
    p_requirement_definition_id: resolved.id,
    p_load_id: null,
    p_expires_at: expiresAt,
  });
  if (error) return { ok: false, error: error.message };
  revalidatePath(`/carriers/${carrierId}`);
  return { ok: true };
}

export async function revokeCarrierComplianceOverrideAction(
  carrierId: string,
  requirementKey: string,
  reason: string
): Promise<ActionResult> {
  const supabase = await createClient();
  const resolved = await resolveRequirementDefinitionId(supabase, requirementKey);
  if ("error" in resolved) return { ok: false, error: resolved.error };

  // Same active-override predicate carrier_dispatch_readiness() itself uses
  // (minus load scoping, which this carrier-wide-only UI never creates), to
  // find the specific row to revoke -- not to decide status.
  const { data: override, error: lookupError } = await supabase
    .from("compliance_overrides")
    .select("id")
    .eq("carrier_id", carrierId)
    .is("revoked_at", null)
    .or(`requirement_definition_id.eq.${resolved.id},requirement_definition_id.is.null`)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (lookupError) return { ok: false, error: lookupError.message };
  if (!override) return { ok: false, error: "No active override was found for this requirement." };

  const { error } = await supabase.rpc("revoke_compliance_override", { p_override_id: override.id, p_reason: reason || null });
  if (error) return { ok: false, error: error.message };
  revalidatePath(`/carriers/${carrierId}`);
  return { ok: true };
}
