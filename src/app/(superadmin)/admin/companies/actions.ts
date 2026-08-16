"use server";

import { revalidatePath } from "next/cache";
import { requirePlatformAdmin } from "@/lib/superadmin/require-platform-admin";

const VALID_STATUSES = ["trialing", "active", "past_due", "paused", "canceled", "incomplete"] as const;

export async function updateOrgSubscription(orgId: string, formData: FormData) {
  // Explicit re-check, in addition to the organization_subscriptions_
  // platform_admin_all RLS policy (0016) that already gates this write at
  // the DB level -- defense in depth, matching every other mutation in
  // this console (spec: "Never rely only on the /admin layout for
  // mutation security"). This action is also the one Suspend/Reactivate
  // Company calls, so it's the most security-sensitive write here.
  const supabase = await requirePlatformAdmin();

  if (!orgId) throw new Error("Missing organization id.");
  const planId = String(formData.get("plan_id") || "");
  const status = String(formData.get("status") || "");
  if (!planId) throw new Error("A subscription plan is required.");
  if (!(VALID_STATUSES as readonly string[]).includes(status)) throw new Error(`Invalid status: ${status}`);

  const { data: existing } = await supabase
    .from("organization_subscriptions")
    .select("id")
    .eq("organization_id", orgId)
    .maybeSingle();

  if (existing) {
    const { error: updateError } = await supabase
      .from("organization_subscriptions")
      .update({ plan_id: planId, status })
      .eq("organization_id", orgId);
    if (updateError) throw new Error(updateError.message);
  } else {
    const now = new Date();
    const periodEnd = new Date(now);
    periodEnd.setMonth(periodEnd.getMonth() + 1);
    const { error: insertError } = await supabase.from("organization_subscriptions").insert({
      organization_id: orgId,
      plan_id: planId,
      status,
      billing_cycle: "monthly",
      current_period_start: now.toISOString(),
      current_period_end: periodEnd.toISOString(),
    });
    if (insertError) throw new Error(insertError.message);
  }

  // Real audit trail for the Platform Console's Recent Activity/Audit Log
  // (spec: "Platform admin action", "Billing change"). p_organization_id
  // is passed explicitly (0044's fix) -- the calling platform admin's own
  // profile has organization_id = null, so log_activity()'s default
  // current_org_id() fallback would otherwise fail here exactly like the
  // driver-portal delivery bug did. Best-effort only: supabase-js resolves
  // rather than throws on RPC errors, so if 0044/0045 haven't been applied
  // yet (the 5-parameter overload or activity_logs itself missing), the
  // error is checked and discarded here -- audit logging must never block
  // the actual subscription update from working.
  const { error: logError } = await supabase.rpc("log_activity", {
    p_entity_type: "organization",
    p_entity_id: orgId,
    p_action: existing ? "subscription_updated" : "subscription_created",
    p_changes: { plan_id: planId, status },
    p_organization_id: orgId,
  });
  if (logError) {
    console.error("log_activity (subscription update) failed -- non-fatal:", logError.message);
  }

  revalidatePath(`/admin/companies/${orgId}`);
  revalidatePath("/admin/companies");
  revalidatePath("/admin/dashboard");
  revalidatePath("/admin/audit-log");
  revalidatePath("/admin/subscriptions");
}
