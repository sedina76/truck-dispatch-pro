"use server";

import { revalidatePath } from "next/cache";
import { createClient as createSupabaseClient } from "@supabase/supabase-js";
import { requirePlatformAdmin } from "@/lib/superadmin/require-platform-admin";
import { createServiceRoleClient } from "@/lib/supabase/service-role";

// Platform Console -> Settings: the signed-in platform admin's OWN account.
// Every action re-checks is_platform_admin() (requirePlatformAdmin) and only
// ever touches the caller's own user -- never an id from the browser.

export type SettingsState = { ok: string | null; error: string | null };

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

async function currentUser() {
  const supabase = await requirePlatformAdmin();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) throw new Error("Not signed in.");
  return { supabase, user };
}

function hasPassword(user: { identities?: { provider: string }[] | null }): boolean {
  return (user.identities ?? []).some((i) => i.provider === "email");
}

/**
 * Confirms the current password without touching the browser session: a
 * throwaway, cookie-less client signs in once and then ends only that new
 * session (scope "local"), so the admin's real session is unaffected.
 */
async function passwordIsCorrect(email: string, password: string): Promise<boolean> {
  const probe = createSupabaseClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { error } = await probe.auth.signInWithPassword({ email, password });
  if (error) return false;
  await probe.auth.signOut({ scope: "local" });
  return true;
}

function siteUrl(): string {
  return (process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000").replace(/\/+$/, "");
}

export async function updateAdminName(_prev: SettingsState, formData: FormData): Promise<SettingsState> {
  const { user } = await currentUser();
  const name = String(formData.get("full_name") ?? "").trim();
  if (name.length < 2 || name.length > 80) return { ok: null, error: "Enter a name between 2 and 80 characters." };

  // platform_admins has a self-SELECT policy only (0016), so the write goes
  // through the service role -- scoped to the caller's own id.
  const admin = createServiceRoleClient();
  const { error } = await admin.from("platform_admins").update({ full_name: name }).eq("id", user.id);
  if (error) return { ok: null, error: "Could not save your name. Try again." };
  await admin.from("profiles").update({ full_name: name }).eq("id", user.id);

  revalidatePath("/admin", "layout");
  return { ok: "Name saved.", error: null };
}

export async function changeAdminEmail(_prev: SettingsState, formData: FormData): Promise<SettingsState> {
  const { supabase, user } = await currentUser();
  const email = String(formData.get("email") ?? "").trim().toLowerCase();
  const password = String(formData.get("current_password") ?? "");

  if (!EMAIL_RE.test(email)) return { ok: null, error: "Enter a valid email address." };
  if (email === (user.email ?? "").toLowerCase()) return { ok: null, error: "That is already your sign-in email." };
  if (hasPassword(user)) {
    if (!password) return { ok: null, error: "Enter your current password to change your email." };
    if (!(await passwordIsCorrect(user.email ?? "", password))) return { ok: null, error: "Current password is incorrect." };
  }

  const { error } = await supabase.auth.updateUser({ email }, { emailRedirectTo: `${siteUrl()}/auth/callback?next=/admin/settings` });
  if (error) {
    const m = error.message.toLowerCase();
    if (m.includes("already") || m.includes("registered")) return { ok: null, error: "Another account already uses that email." };
    if (m.includes("rate")) return { ok: null, error: "Too many attempts. Wait a few minutes and try again." };
    return { ok: null, error: "Could not change your email. Try again." };
  }
  revalidatePath("/admin/settings");
  return {
    ok: `Check ${email} (and your current inbox) for a confirmation link. Your sign-in email changes once you confirm.`,
    error: null,
  };
}

export async function changeAdminPassword(_prev: SettingsState, formData: FormData): Promise<SettingsState> {
  const { supabase, user } = await currentUser();
  const current = String(formData.get("current_password") ?? "");
  const next = String(formData.get("new_password") ?? "");
  const confirm = String(formData.get("confirm_password") ?? "");
  const signOutOthers = formData.get("sign_out_others") === "on";

  if (next.length < 8) return { ok: null, error: "New password must be at least 8 characters." };
  if (next !== confirm) return { ok: null, error: "New passwords do not match." };
  if (hasPassword(user)) {
    if (!current) return { ok: null, error: "Enter your current password." };
    if (current === next) return { ok: null, error: "New password must be different from the current one." };
    if (!(await passwordIsCorrect(user.email ?? "", current))) return { ok: null, error: "Current password is incorrect." };
  }

  const { error } = await supabase.auth.updateUser({ password: next });
  if (error) {
    const m = error.message.toLowerCase();
    if (m.includes("weak") || m.includes("pwned") || m.includes("characters")) return { ok: null, error: "Choose a stronger password (mix letters, numbers and symbols)." };
    if (m.includes("reauthentication")) return { ok: null, error: "For security, sign out and sign back in, then change your password." };
    return { ok: null, error: "Could not change your password. Try again." };
  }
  if (signOutOthers) await supabase.auth.signOut({ scope: "others" });
  return { ok: signOutOthers ? "Password changed. Other devices were signed out." : "Password changed.", error: null };
}

export async function signOutOtherDevices(): Promise<SettingsState> {
  const { supabase } = await currentUser();
  const { error } = await supabase.auth.signOut({ scope: "others" });
  if (error) return { ok: null, error: "Could not sign out other devices. Try again." };
  return { ok: "Signed out everywhere else. This device stays signed in.", error: null };
}
