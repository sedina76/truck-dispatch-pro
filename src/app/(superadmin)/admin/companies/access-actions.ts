"use server";

import { revalidatePath } from "next/cache";
import { requirePlatformAdmin } from "@/lib/superadmin/require-platform-admin";

// Two platform-only switches on a company, both on the organizations row:
//
//   is_active        false = suspended. Enforced for EVERY company by
//                    resolveBillingAccess() (middleware + operational
//                    access), free-access and legacy companies included.
//   billing_required false = free access (no subscription needed).
//
// Written through the caller's RLS client: organizations_platform_admin_update
// (0046) allows it, and migration 0171 stops a company's own owner from
// changing either column. requirePlatformAdmin() re-checks the caller too.

function revalidateCompany(orgId: string) {
  revalidatePath(`/admin/companies/${orgId}`);
  revalidatePath("/admin/companies");
  revalidatePath("/admin/dashboard");
  revalidatePath("/admin/reports");
  revalidatePath("/admin/audit-log");
}

async function logAction(supabase: Awaited<ReturnType<typeof requirePlatformAdmin>>, orgId: string, action: string, changes: Record<string, unknown>) {
  // Best-effort audit entry, same convention as updateOrgSubscription():
  // a logging failure never undoes or blocks the change itself.
  const { error } = await supabase.rpc("log_activity", {
    p_entity_type: "organization",
    p_entity_id: orgId,
    p_action: action,
    p_changes: changes,
    p_organization_id: orgId,
  });
  if (error) console.error(`log_activity (${action}) failed -- non-fatal:`, error.message);
}

export async function setCompanySuspended(orgId: string, suspend: boolean): Promise<void> {
  const supabase = await requirePlatformAdmin();
  if (!orgId) throw new Error("Missing company id.");

  const { data, error } = await supabase.from("organizations").update({ is_active: !suspend }).eq("id", orgId).select("id").maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) throw new Error("Company not found.");

  // Companies suspended the old way (subscription status = paused) come
  // back fully on Reactivate, as they did before.
  if (!suspend) {
    const { error: subError } = await supabase.from("organization_subscriptions").update({ status: "active" }).eq("organization_id", orgId).eq("status", "paused");
    if (subError) throw new Error(subError.message);
  }

  await logAction(supabase, orgId, suspend ? "company_suspended" : "company_reactivated", { is_active: !suspend });
  revalidateCompany(orgId);
}

export async function setCompanyFreeAccess(orgId: string, free: boolean): Promise<void> {
  const supabase = await requirePlatformAdmin();
  if (!orgId) throw new Error("Missing company id.");

  const { data, error } = await supabase.from("organizations").update({ billing_required: !free }).eq("id", orgId).select("id").maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) throw new Error("Company not found.");

  await logAction(supabase, orgId, free ? "free_access_granted" : "subscription_required", { billing_required: !free });
  revalidateCompany(orgId);
}
