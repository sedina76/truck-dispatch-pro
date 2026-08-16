"use server";

import { randomBytes } from "node:crypto";
import { revalidatePath } from "next/cache";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { EMAIL_PROVIDER_CONFIGURED } from "@/lib/email/provider";
import { requirePlatformAdmin } from "@/lib/superadmin/require-platform-admin";

// Every action here follows the same rule as the rest of the Platform
// Console: it re-checks is_platform_admin() itself (via the SECURITY
// DEFINER RPCs in 0046, or explicitly before any Admin API call), never
// trusting that the caller already passed the superadmin layout gate.
// Sensitive Supabase Auth Admin API calls (createUser, updateUserById,
// deleteUser) only ever happen in this "use server" file, using
// createServiceRoleClient() -- never imported into a "use client"
// component, never returned to the browser.

function slugify(name: string): string {
  return (
    name
      .toLowerCase()
      .trim()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "") +
    "-" +
    Math.random().toString(36).slice(2, 6)
  );
}

function generateTempPassword(): string {
  // 18 random bytes -> 24-char base64url-ish string, well above the app's
  // own 8-char minimum. Never logged, never stored -- returned exactly
  // once to the calling platform admin's own browser for one-time display.
  return randomBytes(18).toString("base64").replace(/[+/=]/g, "").slice(0, 20) + "!Aa1";
}

const VALID_ROLES = ["owner", "admin", "dispatcher", "accountant", "driver", "viewer"] as const;

function assertValidRole(role: string): asserts role is (typeof VALID_ROLES)[number] {
  if (!(VALID_ROLES as readonly string[]).includes(role)) throw new Error(`Invalid role: ${role}`);
}

// ---------------------------------------------------------------------------
// Add Company (spec sections 10-12). Sequence: create auth user -> create
// organization + owner linkage (one atomic RPC) -> optional org profile
// fields -> optional subscription -> audit log. If organization creation
// fails after the auth user was created, the auth user (and its
// auto-created profile, via ON DELETE CASCADE) is deleted so nothing is
// ever left half-created.
// ---------------------------------------------------------------------------
export async function createCompany(formData: FormData): Promise<{ orgId: string; tempPassword: string; adminEmail: string }> {
  // `supabase` (the RLS-scoped client, carrying the calling platform
  // admin's own JWT) is required for platform_create_organization_with_owner
  // below -- that RPC is SECURITY DEFINER but still checks is_platform_admin()
  // internally via auth.uid(), which only resolves for a real user session.
  // `admin` (service-role) has no JWT/auth.uid() at all, so calling that RPC
  // through it would always fail its own internal check regardless of who's
  // really calling -- service-role is only for the Auth Admin API below.
  const supabase = await requirePlatformAdmin();
  const admin = createServiceRoleClient();

  const companyName = String(formData.get("company_name") || "").trim();
  if (!companyName) throw new Error("Company name is required.");
  const slugInput = String(formData.get("slug") || "").trim();
  const slug = slugInput ? slugInput.toLowerCase().replace(/[^a-z0-9-]+/g, "-") : slugify(companyName);

  const adminFirstName = String(formData.get("admin_first_name") || "").trim();
  const adminLastName = String(formData.get("admin_last_name") || "").trim();
  const adminEmail = String(formData.get("admin_email") || "").trim().toLowerCase();
  if (!adminFirstName || !adminLastName || !adminEmail) throw new Error("Primary admin name and email are required.");
  const fullName = `${adminFirstName} ${adminLastName}`;

  const tempPassword = generateTempPassword();

  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email: adminEmail,
    password: tempPassword,
    email_confirm: true,
    user_metadata: { full_name: fullName },
  });
  if (createError || !created.user) {
    throw new Error(createError?.message ?? "Could not create the primary admin account.");
  }
  const ownerUserId = created.user.id;

  try {
    const { data: org, error: orgError } = await supabase.rpc("platform_create_organization_with_owner", {
      p_name: companyName,
      p_slug: slug,
      p_owner_user_id: ownerUserId,
    });
    if (orgError || !org) throw new Error(orgError?.message ?? "Could not create the organization.");

    const orgRow = Array.isArray(org) ? org[0] : org;

    const phone = String(formData.get("phone") || "").trim();
    const contactEmail = String(formData.get("contact_email") || "").trim();
    const address = String(formData.get("address") || "").trim();
    const timezone = String(formData.get("timezone") || "").trim();
    const profileUpdates: Record<string, string> = {};
    if (phone) profileUpdates.business_phone = phone;
    if (contactEmail) profileUpdates.business_email = contactEmail;
    if (address) profileUpdates.address_line1 = address;
    if (timezone) profileUpdates.timezone = timezone;
    if (Object.keys(profileUpdates).length > 0) {
      await admin.from("organizations").update(profileUpdates).eq("id", orgRow.id);
    }

    const planId = String(formData.get("plan_id") || "");
    const status = String(formData.get("status") || "");
    if (planId && status) {
      const now = new Date();
      const periodEnd = new Date(now);
      periodEnd.setMonth(periodEnd.getMonth() + 1);
      await admin.from("organization_subscriptions").insert({
        organization_id: orgRow.id,
        plan_id: planId,
        status,
        billing_cycle: "monthly",
        current_period_start: now.toISOString(),
        current_period_end: periodEnd.toISOString(),
      });
    }

    await supabase.rpc("log_activity", {
      p_entity_type: "organization",
      p_entity_id: orgRow.id,
      p_action: "company_created",
      p_changes: { name: companyName, slug, primary_admin_email: adminEmail },
      p_organization_id: orgRow.id,
    });

    revalidatePath("/admin/companies");
    revalidatePath("/admin/dashboard");
    revalidatePath("/admin/audit-log");

    return { orgId: orgRow.id, tempPassword, adminEmail };
  } catch (err) {
    // Rollback: never leave an auth user (and its auto-created profile)
    // without an organization.
    await admin.auth.admin.deleteUser(ownerUserId);
    throw err instanceof Error ? err : new Error("Company creation failed.");
  }
}

// ---------------------------------------------------------------------------
// Add Admin to an existing company (spec section 13). Same
// create-then-rollback-on-failure shape as createCompany.
// ---------------------------------------------------------------------------
export async function addCompanyAdmin(
  orgId: string,
  formData: FormData
): Promise<{ tempPassword: string; email: string }> {
  // Same reasoning as createCompany above: platform_assign_user_to_org and
  // log_activity must be called through the RLS-scoped `supabase` client
  // (carries the real platform admin's JWT / auth.uid()), never through
  // the service-role `admin` client -- a service-role call has no
  // auth.uid() at all, which would make is_platform_admin() fail inside
  // the RPC (rejecting every legitimate call) and would silently record
  // audit entries with actor_id = null instead of the real caller.
  const supabase = await requirePlatformAdmin();
  const admin = createServiceRoleClient();

  const firstName = String(formData.get("first_name") || "").trim();
  const lastName = String(formData.get("last_name") || "").trim();
  const email = String(formData.get("email") || "").trim().toLowerCase();
  const role = String(formData.get("role") || "dispatcher");
  assertValidRole(role);
  if (!firstName || !lastName || !email) throw new Error("Name and email are required.");

  const tempPassword = generateTempPassword();
  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    password: tempPassword,
    email_confirm: true,
    user_metadata: { full_name: `${firstName} ${lastName}` },
  });
  if (createError || !created.user) {
    throw new Error(createError?.message ?? "Could not create the admin account.");
  }
  const userId = created.user.id;

  try {
    const { error: assignError } = await supabase.rpc("platform_assign_user_to_org", {
      p_user_id: userId,
      p_org_id: orgId,
      p_role: role,
    });
    if (assignError) throw new Error(assignError.message);

    await supabase.rpc("log_activity", {
      p_entity_type: "organization",
      p_entity_id: orgId,
      p_action: "admin_created",
      p_changes: { email, role },
      p_organization_id: orgId,
    });

    revalidatePath(`/admin/companies/${orgId}`);
    revalidatePath("/admin/audit-log");
    return { tempPassword, email };
  } catch (err) {
    await admin.auth.admin.deleteUser(userId);
    throw err instanceof Error ? err : new Error("Adding admin failed.");
  }
}

// ---------------------------------------------------------------------------
// Company Profile edit (spec sections 2-3). Explicit allowlist of real
// organizations columns only. Slug uniqueness is enforced by the existing
// DB unique constraint (organizations.slug) -- a collision surfaces as a
// clear error, never a silent overwrite.
// ---------------------------------------------------------------------------
export async function updateCompanyProfile(orgId: string, formData: FormData) {
  const supabase = await requirePlatformAdmin();

  const name = String(formData.get("name") || "").trim();
  if (!name) throw new Error("Company name is required.");
  const slug = String(formData.get("slug") || "").trim().toLowerCase();
  if (!slug) throw new Error("Slug is required.");

  const updates = {
    name,
    slug,
    dba_name: emptyToNull(formData.get("dba_name")),
    business_phone: emptyToNull(formData.get("business_phone")),
    business_email: emptyToNull(formData.get("business_email")),
    website: emptyToNull(formData.get("website")),
    address_line1: emptyToNull(formData.get("address_line1")),
    city: emptyToNull(formData.get("city")),
    state: emptyToNull(formData.get("state")),
    postal_code: emptyToNull(formData.get("postal_code")),
    country: emptyToNull(formData.get("country")) ?? "US",
    timezone: emptyToNull(formData.get("timezone")) ?? "America/Chicago",
  };

  // .select("id") + a row-count check is required here, not optional: a
  // plain .update() with no matching RLS-visible row returns { error: null,
  // data: null } from supabase-js -- it does NOT surface as an error. Without
  // this check, an UPDATE blocked by RLS (e.g. organizations_platform_admin_
  // update from 0046 not yet applied) would silently report success while
  // changing nothing -- exactly the "button does nothing" symptom reported.
  const { data: updated, error } = await supabase.from("organizations").update(updates).eq("id", orgId).select("id");
  if (error) {
    if (error.code === "23505") throw new Error(`The slug "${slug}" is already in use by another company.`);
    throw new Error(error.message);
  }
  if (!updated || updated.length === 0) {
    throw new Error("Company not found, or you are not authorized to edit it. (If this persists, RUN_THIS_FOR_PLATFORM_COMPANY_MANAGEMENT.sql may not have been applied yet.)");
  }

  await supabase.rpc("log_activity", {
    p_entity_type: "organization",
    p_entity_id: orgId,
    p_action: "company_profile_updated",
    p_changes: updates,
    p_organization_id: orgId,
  });

  revalidatePath(`/admin/companies/${orgId}`);
  revalidatePath("/admin/companies");
  revalidatePath("/admin/audit-log");
}

// ---------------------------------------------------------------------------
// Admin profile edit (spec sections 7, 9). full_name/phone go through the
// plain RLS-scoped client (profiles_platform_admin_update, 0046). Email
// changes update BOTH auth.users (Admin API) and profiles.email, kept in
// sync per the existing mirror convention -- never just one side.
// ---------------------------------------------------------------------------
export async function updateAdminProfile(userId: string, orgId: string, formData: FormData) {
  const supabase = await requirePlatformAdmin();

  const fullName = String(formData.get("full_name") || "").trim();
  const phone = emptyToNull(formData.get("phone"));
  const newEmail = String(formData.get("email") || "").trim().toLowerCase();

  if (!fullName) throw new Error("Name is required.");

  const { data: current } = await supabase.from("profiles").select("email").eq("id", userId).single();
  const emailChanged = current && newEmail && newEmail !== current.email;

  if (emailChanged) {
    const admin = createServiceRoleClient();
    const { error: authError } = await admin.auth.admin.updateUserById(userId, { email: newEmail });
    if (authError) {
      throw new Error(authError.message.includes("already been registered") ? "That email is already in use by another account." : authError.message);
    }
  }

  const { data: updated, error } = await supabase
    .from("profiles")
    .update({ full_name: fullName, phone, ...(emailChanged ? { email: newEmail } : {}) })
    .eq("id", userId)
    .select("id");
  if (error) throw new Error(error.message);
  if (!updated || updated.length === 0) {
    throw new Error("Admin not found, or you are not authorized to edit it. (If this persists, RUN_THIS_FOR_PLATFORM_COMPANY_MANAGEMENT.sql may not have been applied yet.)");
  }

  await supabase.rpc("log_activity", {
    p_entity_type: "organization",
    p_entity_id: orgId,
    p_action: "admin_profile_updated",
    p_changes: { user_id: userId, full_name: fullName, email_changed: !!emailChanged },
    p_organization_id: orgId,
  });

  revalidatePath(`/admin/companies/${orgId}`);
  revalidatePath("/admin/audit-log");
}

// ---------------------------------------------------------------------------
// Role change -- last-owner protection enforced inside
// platform_update_user_role() at the DB level, not just in the UI.
// ---------------------------------------------------------------------------
export async function changeAdminRole(userId: string, orgId: string, formData: FormData) {
  const supabase = await requirePlatformAdmin();
  const role = String(formData.get("role") || "");
  assertValidRole(role);

  const { error } = await supabase.rpc("platform_update_user_role", { p_user_id: userId, p_role: role });
  if (error) throw new Error(error.message);

  await supabase.rpc("log_activity", {
    p_entity_type: "organization",
    p_entity_id: orgId,
    p_action: "admin_role_changed",
    p_changes: { user_id: userId, role },
    p_organization_id: orgId,
  });

  revalidatePath(`/admin/companies/${orgId}`);
  revalidatePath("/admin/audit-log");
}

// ---------------------------------------------------------------------------
// Deactivate/Reactivate (spec section 15). Auth-level ban is the real
// access block; profiles.is_active is kept consistent (same field the
// tenant-side Settings -> Users page already uses) rather than adding a
// second status field. Historical rows referencing this user
// (created_by/approved_by/settlement records/audit logs) are untouched --
// this never deletes the profile.
// ---------------------------------------------------------------------------
export async function setAdminActive(userId: string, orgId: string, isActive: boolean) {
  const supabase = await requirePlatformAdmin();
  const admin = createServiceRoleClient();

  const { error: roleError } = await supabase.rpc("platform_set_user_active", { p_user_id: userId, p_is_active: isActive });
  if (roleError) throw new Error(roleError.message);

  const { error: banError } = await admin.auth.admin.updateUserById(userId, {
    ban_duration: isActive ? "none" : "876000h", // ~100 years -- Supabase's convention for "indefinite"
  });
  if (banError) throw new Error(banError.message);

  await supabase.rpc("log_activity", {
    p_entity_type: "organization",
    p_entity_id: orgId,
    p_action: isActive ? "user_reactivated" : "user_deactivated",
    p_changes: { user_id: userId },
    p_organization_id: orgId,
  });

  revalidatePath(`/admin/companies/${orgId}`);
  revalidatePath("/admin/audit-log");
}

// ---------------------------------------------------------------------------
// Password management (spec section 8). Set Temporary Password is the
// real, working path (no email provider configured -- confirmed, see
// src/lib/email/provider.ts). Send Password Reset Email is offered but
// honestly reports the same "not configured" state the rest of the app
// already does for email -- never faked.
// ---------------------------------------------------------------------------
export async function setTemporaryPassword(userId: string, orgId: string): Promise<{ tempPassword: string }> {
  const supabase = await requirePlatformAdmin();
  const admin = createServiceRoleClient();

  const tempPassword = generateTempPassword();
  const { error } = await admin.auth.admin.updateUserById(userId, { password: tempPassword });
  if (error) throw new Error(error.message);

  // Never log the password itself -- only the fact that a reset happened.
  await supabase.rpc("log_activity", {
    p_entity_type: "organization",
    p_entity_id: orgId,
    p_action: "temporary_password_set",
    p_changes: { user_id: userId },
    p_organization_id: orgId,
  });

  revalidatePath(`/admin/companies/${orgId}`);
  revalidatePath("/admin/audit-log");
  return { tempPassword };
}

export async function sendPasswordResetEmail(userId: string, orgId: string, email: string): Promise<{ ok: boolean; error?: string }> {
  const supabase = await requirePlatformAdmin();

  if (!EMAIL_PROVIDER_CONFIGURED) {
    const error = "Email provider not configured.";
    await supabase.rpc("log_activity", {
      p_entity_type: "organization",
      p_entity_id: orgId,
      p_action: "password_reset_blocked",
      p_changes: { user_id: userId, error },
      p_organization_id: orgId,
    });
    revalidatePath("/admin/audit-log");
    return { ok: false, error };
  }

  // Unreachable until a real provider is wired in -- see src/lib/email/provider.ts.
  const admin = createServiceRoleClient();
  const { error } = await admin.auth.resetPasswordForEmail(email);
  if (error) return { ok: false, error: error.message };

  await supabase.rpc("log_activity", {
    p_entity_type: "organization",
    p_entity_id: orgId,
    p_action: "password_reset_initiated",
    p_changes: { user_id: userId },
    p_organization_id: orgId,
  });
  return { ok: true };
}

function emptyToNull(value: FormDataEntryValue | null): string | null {
  const s = value == null ? "" : String(value).trim();
  return s === "" ? null : s;
}
