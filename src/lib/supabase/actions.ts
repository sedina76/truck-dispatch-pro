"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export type ActionState = { error: string | null };

// Translates Supabase Auth's raw error text into the exact user-facing
// copy the auth redesign spec calls for (section 17) -- never a raw
// provider message shown to the visitor. Falls back to the original
// message for anything not explicitly anticipated, rather than hiding an
// unexpected error behind a useless generic string.
function friendlyAuthError(raw: string): string {
  const m = raw.toLowerCase();
  if (m.includes("invalid login credentials")) return "Incorrect email or password.";
  if (m.includes("already registered") || m.includes("already exists") || m.includes("user already registered")) return "Email already registered.";
  if (m.includes("email not confirmed")) return "Please verify your email before signing in.";
  if ((m.includes("token") || m.includes("otp") || m.includes("code")) && m.includes("expired")) return "Verification code expired.";
  if (m.includes("token has expired or is invalid") || m.includes("invalid otp") || m.includes("invalid token")) return "Invalid verification code.";
  if (m.includes("for security purposes") || m.includes("rate limit") || m.includes("too many requests")) return "Too many attempts — try again shortly.";
  return raw;
}

export async function login(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const supabase = await createClient();

  const { error } = await supabase.auth.signInWithPassword({
    email: String(formData.get("email")),
    password: String(formData.get("password")),
  });

  if (error) return { error: friendlyAuthError(error.message) };

  redirect("/dashboard");
}

export async function signup(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const supabase = await createClient();
  const email = String(formData.get("email"));
  const password = String(formData.get("password"));
  const confirmPassword = String(formData.get("confirmPassword") ?? "");

  if (confirmPassword && password !== confirmPassword) {
    return { error: "Passwords do not match." };
  }

  const { data, error } = await supabase.auth.signUp({ email, password });

  if (error) return { error: friendlyAuthError(error.message) };

  // Email confirmation enabled: no session yet -- send to the OTP
  // verification screen (spec section 7), not straight to login. A
  // confirmed project (email confirmations off) returns a session
  // immediately, so this branch is skipped entirely for that config.
  if (!data.session) {
    redirect(`/verify-email?email=${encodeURIComponent(email)}`);
  }

  redirect("/onboarding");
}

export async function logout() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login");
}

export type CreateOrganizationState = ActionState;

// Extended (spec section 10) to also collect dot_number/mc_number/
// business_phone/timezone -- all pre-existing organizations columns (see
// 0002/later migrations), none of which the original
// create_organization_with_owner RPC (0012) accepts as a parameter. Rather
// than change that RPC's signature (a migration, and a second thing that
// could break the platform-admin analog in 0046 which calls the same
// pattern), the org is created via the RPC EXACTLY as before, then a
// plain, ordinary UPDATE sets the extra fields -- allowed by the existing
// organizations_update RLS policy (0010: owner of current_org_id()),
// which the RPC has already made true by the time this second statement
// runs, since it promotes the caller to owner before returning. No new
// migration, no duplicated organization-creation logic.
export async function createOrganization(
  _prev: CreateOrganizationState,
  formData: FormData
): Promise<CreateOrganizationState> {
  const supabase = await createClient();
  const name = String(formData.get("name") || "").trim();
  if (!name) return { error: "Company name is required." };

  const slug =
    name
      .toLowerCase()
      .trim()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "") +
    "-" +
    Math.random().toString(36).slice(2, 6);

  const { data: org, error } = await supabase.rpc("create_organization_with_owner", {
    p_name: name,
    p_slug: slug,
  });

  if (error) return { error: error.message };

  const dotNumber = String(formData.get("dotNumber") || "").trim();
  const mcNumber = String(formData.get("mcNumber") || "").trim();
  const businessPhone = String(formData.get("businessPhone") || "").trim();
  const timezone = String(formData.get("timezone") || "").trim();

  const extra: Record<string, string> = {};
  if (dotNumber) extra.dot_number = dotNumber;
  if (mcNumber) extra.mc_number = mcNumber;
  if (businessPhone) extra.business_phone = businessPhone;
  if (timezone) extra.timezone = timezone;

  if (Object.keys(extra).length > 0 && org) {
    // Best-effort: the organization itself is already created and the
    // caller is already its owner at this point -- a failure here is
    // never allowed to strand the user mid-onboarding with no org at all.
    // They can fill these in later from Settings -> Organization.
    await supabase.from("organizations").update(extra).eq("id", org.id);
  }

  redirect("/dashboard");
}

// ---------------------------------------------------------------------------
// Email verification (OTP) -- spec sections 7-9. Uses Supabase Auth's own
// verifyOtp()/resend() -- no custom code generator, no application-table
// storage of a code, ever.
// ---------------------------------------------------------------------------
export type VerifyOtpState = { error: string | null };

export async function verifySignupOtp(_prev: VerifyOtpState, formData: FormData): Promise<VerifyOtpState> {
  const supabase = await createClient();
  const email = String(formData.get("email") || "");
  const token = String(formData.get("token") || "");

  if (!/^\d{6}$/.test(token)) return { error: "Enter the 6-digit code." };

  const { error } = await supabase.auth.verifyOtp({ email, token, type: "signup" });
  if (error) return { error: friendlyAuthError(error.message) };

  redirect("/onboarding");
}

export type ResendOtpState = { error: string | null; sent: boolean };

export async function resendSignupOtp(_prev: ResendOtpState, formData: FormData): Promise<ResendOtpState> {
  const supabase = await createClient();
  const email = String(formData.get("email") || "");

  const { error } = await supabase.auth.resend({ type: "signup", email });
  if (error) return { error: friendlyAuthError(error.message), sent: false };

  return { error: null, sent: true };
}

// ---------------------------------------------------------------------------
// Forgot password (spec section 12) -- Supabase Auth's own recovery flow.
// Always returns a generic success message regardless of whether the
// email actually exists (matches Supabase's own resetPasswordForEmail
// behavior of not distinguishing the two server-side either), so this
// screen can never be used to enumerate registered accounts.
// ---------------------------------------------------------------------------
export type RequestResetState = { error: string | null; sent: boolean };

export async function requestPasswordReset(_prev: RequestResetState, formData: FormData): Promise<RequestResetState> {
  const supabase = await createClient();
  const email = String(formData.get("email") || "").trim();
  if (!email) return { error: "Enter your email address.", sent: false };

  const siteUrl = process.env.NEXT_PUBLIC_SITE_URL || "http://localhost:3000";
  // Found live during the Phase 2F-A SMTP audit: NEXT_PUBLIC_SITE_URL is
  // not set in this environment, so this falls back to localhost -- fine
  // for `npm run dev`, but a REAL password-recovery email sent from a
  // deployed instance without this var set would link a real person to
  // their own laptop's localhost. Never guessed/hardcoded here (this repo
  // has no way to know the real production URL) -- surfaced loudly in
  // server logs instead of failing silently, so a misconfigured deploy is
  // caught immediately rather than discovered via a support ticket.
  if (!process.env.NEXT_PUBLIC_SITE_URL && process.env.NODE_ENV === "production") {
    console.error("[auth] NEXT_PUBLIC_SITE_URL is not set in production -- password-reset emails will link to localhost. Set it to the real deployed URL.");
  }
  await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: `${siteUrl}/auth/callback?next=/reset-password`,
  });

  // Deliberately ignore the error result for the response shown to the
  // visitor (see header comment) -- a real failure (provider down, etc.)
  // is still visible in server logs via Supabase's own error reporting.
  return { error: null, sent: true };
}

export type UpdatePasswordState = { error: string | null };

export async function updatePassword(_prev: UpdatePasswordState, formData: FormData): Promise<UpdatePasswordState> {
  const supabase = await createClient();
  const password = String(formData.get("password") || "");
  const confirmPassword = String(formData.get("confirmPassword") || "");

  if (password !== confirmPassword) return { error: "Passwords do not match." };
  if (password.length < 8) return { error: "Password must be at least 8 characters." };

  const { error } = await supabase.auth.updateUser({ password });
  if (error) return { error: friendlyAuthError(error.message) };

  await supabase.auth.signOut();
  redirect("/login?reset=1");
}
