"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

type ActionResult<T = undefined> = T extends undefined ? { ok: true } | { ok: false; error: string } : { ok: true; data: T } | { ok: false; error: string };

// Phase 2N.2 -- staff-side W-9 actions. Owner/Admin only, reason required,
// audited -- mirrors the existing reveal_carrier_onboarding_ein() staff
// action pattern used elsewhere in this same onboarding surface. NOT YET
// LIVE: depends on migration 0099 (not applied).
export async function revealCarrierW9Tin(w9Id: string, reason: string): Promise<ActionResult<{ tin: string }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reveal_carrier_w9_tin", { p_w9_id: w9Id, p_reason: reason });
  if (error) return { ok: false, error: error.message };
  return { ok: true, data: { tin: data as string } };
}

export async function voidCarrierW9(w9Id: string, applicationId: string, organizationId: string, reason: string): Promise<ActionResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("void_carrier_w9", { p_w9_id: w9Id, p_organization_id: organizationId, p_reason: reason });
  if (error) return { ok: false, error: error.message };
  revalidatePath(`/carriers/onboarding/${applicationId}`);
  return { ok: true };
}
