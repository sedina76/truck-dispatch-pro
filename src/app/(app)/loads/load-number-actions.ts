"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { checkOperationalAccess } from "@/lib/billing/operational-access";
import { OWNER_ADMIN_ROLES, type OrgRole } from "@/lib/auth/require-role";

// Controlled Owner/Admin load-number override (0114 revision 2). The
// database (guard_load_number_change(), a BEFORE UPDATE trigger, and
// change_load_number(), the RPC this action calls) is the actual,
// unconditional authority here -- everything this action does BEFORE
// calling that RPC is a defense-in-depth / better-UX pass, not a
// substitute for it. Per spec: never trust a client-supplied
// organization_id, and never trust a client-supplied "current number" --
// this action's signature has no such parameters at all; the load's real
// current organization_id and load_number are always re-read fresh from
// the database.
export type ChangeLoadNumberResult = { ok: true; loadNumber: string } | { ok: false; error: string };

const LIFECYCLE_LOCKED_MESSAGE = "Load number cannot be changed after dispatch or billing activity has begun.";

export async function changeLoadNumber(loadId: string, newNumber: string, reason: string): Promise<ChangeLoadNumberResult> {
  const trimmedReason = reason.trim();
  const trimmedNumber = newNumber.trim();
  if (!trimmedReason) return { ok: false, error: "A reason is required to change a load number." };
  if (!trimmedNumber) return { ok: false, error: "Load number cannot be blank." };

  const supabase = await createClient();

  // ---- Verify owner/admin (mirrors the database's own has_role() check,
  // for a fast, clear rejection before even attempting the RPC) ---------
  const { data: roleData } = await supabase.rpc("current_role");
  const role = roleData as OrgRole | null;
  if (!role || !OWNER_ADMIN_ROLES.includes(role)) {
    return { ok: false, error: "Only owners or admins may change a load number." };
  }

  // D.2.11 SaaS paywall -- before the change_load_number RPC write.
  const access = await checkOperationalAccess();
  if (!access.ok) {
    return { ok: false, error: "Your organization's subscription does not permit this action." };
  }

  // ---- Re-fetch the load scoped to the CALLER's own organization -------
  // (never the client's claim of which organization it belongs to --
  // getCurrentOrgId() resolves the authenticated user's own organization
  // server-side, and the query below is additionally RLS-scoped
  // regardless).
  let orgId: string;
  try {
    orgId = await getCurrentOrgId();
  } catch {
    return { ok: false, error: "Could not determine the current organization for this user." };
  }
  const { data: load } = await supabase.from("loads").select("id, load_number").eq("id", loadId).eq("organization_id", orgId).maybeSingle();
  if (!load) return { ok: false, error: "Load not found." };
  if (load.load_number === trimmedNumber) {
    return { ok: false, error: "That is already this load's number." };
  }

  // ---- Re-fetch lifecycle state (dispatch/invoice existence) -----------
  // Purely for a clear, immediate message -- the database trigger
  // enforces this unconditionally regardless of what this check finds
  // (e.g. a dispatch created in the moment between this check and the
  // actual UPDATE below is still caught, just by the trigger instead).
  const [{ data: dispatchRow }, { data: invoiceRow }] = await Promise.all([
    supabase.from("dispatches").select("id").eq("load_id", loadId).limit(1).maybeSingle(),
    supabase.from("invoices").select("id").eq("load_id", loadId).limit(1).maybeSingle(),
  ]);
  if (dispatchRow || invoiceRow) {
    return { ok: false, error: LIFECYCLE_LOCKED_MESSAGE };
  }

  // ---- Call the controlled database mechanism ---------------------------
  // change_load_number() re-verifies every one of the above independently
  // (role, organization, lifecycle, non-empty reason/number) and is the
  // real, unconditional authority -- this call cannot be bypassed by
  // anything this action decided above.
  const { data, error } = await supabase.rpc("change_load_number", {
    p_load_id: loadId,
    p_new_number: trimmedNumber,
    p_reason: trimmedReason,
  });

  if (error) {
    if (error.code === "23505" || error.message?.toLowerCase().includes("already in use")) {
      return { ok: false, error: `Load number "${trimmedNumber}" is already in use in this organization.` };
    }
    if (error.message?.includes("dispatch or billing activity")) {
      return { ok: false, error: LIFECYCLE_LOCKED_MESSAGE };
    }
    if (error.message?.toLowerCase().includes("owners or admins")) {
      return { ok: false, error: "Only owners or admins may change a load number." };
    }
    return { ok: false, error: error.message };
  }

  const updated = data as { load_number: string } | null;
  revalidatePath(`/loads/${loadId}`);
  revalidatePath("/loads");
  return { ok: true, loadNumber: updated?.load_number ?? trimmedNumber };
}
