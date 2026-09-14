"use server";

import { redirect } from "next/navigation";
import { createHash } from "node:crypto";
import { createClient } from "@/lib/supabase/server";
import { SIGNUP_OTP_LENGTH } from "@/lib/auth/otp";
import {
  normalizeSignupEmail,
  signupVerificationErrorMessage,
  type SupabaseAuthErrorLike,
} from "@/lib/auth/signup-verification";

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
  // Auth signup/verification defect audit: resend({type:"signup"}) returns
  // this exact message for an email that's already confirmed -- distinct
  // from "email not confirmed" above (that's the LOGIN-time message for an
  // unconfirmed account). Belt-and-suspenders: signup() below now avoids
  // ever sending an already-confirmed user to the verify-email screen in
  // the first place, but this still covers a stale link or a direct
  // /verify-email visit.
  if (m.includes("already confirmed")) return "This email is already verified. Try signing in instead.";
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
  const email = normalizeSignupEmail(formData.get("email"));
  const password = String(formData.get("password"));
  const confirmPassword = String(formData.get("confirmPassword") ?? "");

  if (confirmPassword && password !== confirmPassword) {
    return { error: "Passwords do not match." };
  }

  const { data, error } = await supabase.auth.signUp({ email, password });

  if (error) return { error: friendlyAuthError(error.message) };

  // Auth signup/verification defect audit -- root cause: Supabase Auth's
  // signUp() has a deliberate, documented anti-enumeration behavior for an
  // email that already belongs to a CONFIRMED user -- it returns success
  // (no `error`), `data.session === null` (same shape as a genuine new
  // signup), and sends NO email at all. GoTrue logs this exact case as
  // "User repeated signup: request completed". Before this fix, the `if
  // (!data.session)` check below couldn't tell that case apart from a real
  // new signup and sent the user to "We sent a verification code to..."
  // regardless -- which is exactly why a repeated signup with an
  // already-verified test address showed that screen but no email ever
  // arrived; nothing was ever sent to arrive.
  //
  // Supabase's own documented signal for this is `data.user.identities`:
  // empty for the already-confirmed short-circuit, populated for a
  // genuine new user AND for an existing-but-UNCONFIRMED user (which DOES
  // get a real resend, and is correctly left on the path below unchanged).
  // This does mean the response now distinguishes "this email already has
  // a verified account" for someone submitting the signup form with it --
  // the same trade-off essentially every production signup form makes
  // (and one Supabase itself hands the calling application this exact
  // signal to make), not a new information leak: nothing here exposes any
  // OTHER account detail, and login/password-reset are unaffected.
  if (data.user && data.user.identities && data.user.identities.length === 0) {
    return { error: "This email is already registered and verified. Try signing in, or use “Forgot password” if you don't remember your password." };
  }

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

function logSignupVerificationFailure(
  operation: "verify_signup_otp" | "resend_signup_otp",
  email: string,
  error: SupabaseAuthErrorLike
) {
  console.error("[auth] signup verification failed", {
    operation,
    verificationType: "signup",
    errorCode: error.code ?? "unknown",
    httpStatus: error.status ?? null,
    emailHash: createHash("sha256").update(email).digest("hex").slice(0, 16),
  });
}

export async function verifySignupOtp(_prev: VerifyOtpState, formData: FormData): Promise<VerifyOtpState> {
  const supabase = await createClient();
  const email = normalizeSignupEmail(formData.get("email"));
  const token = String(formData.get("token") || "");

  // The signup confirmation code is exactly SIGNUP_OTP_LENGTH digits (6 --
  // Supabase Auth's default, matching this project's "Email OTP Length"
  // Dashboard setting). Shorter or longer input is rejected here, before
  // ever calling Supabase, with a clear message naming the required length
  // -- never silently truncated or padded. The application constant and the
  // Dashboard setting must stay in agreement (see src/lib/auth/otp.ts).
  if (!new RegExp(`^\\d{${SIGNUP_OTP_LENGTH}}$`).test(token)) {
    return { error: `Enter the ${SIGNUP_OTP_LENGTH}-digit code.` };
  }

  try {
    const { error } = await supabase.auth.verifyOtp({ email, token, type: "signup" });
    if (error) {
      // A completed retry or a second click can reach this branch after the
      // first request established the session. Continue without creating
      // anything; /onboarding performs its existing profile/org guard.
      const { data: { user } } = await supabase.auth.getUser();
      if (!user?.email_confirmed_at) {
        logSignupVerificationFailure("verify_signup_otp", email, error);
        return { error: signupVerificationErrorMessage(error) };
      }
      // Continue below and redirect outside the catch block: Next's
      // redirect() deliberately throws a framework control-flow exception.
    }
  } catch (error) {
    const safeError = error instanceof Error ? error : new Error("Unknown verification failure");
    logSignupVerificationFailure("verify_signup_otp", email, safeError);
    return { error: signupVerificationErrorMessage(safeError) };
  }

  redirect("/onboarding");
}

export type ResendOtpState = { error: string | null; sent: boolean; sentAt?: number };

export async function resendSignupOtp(_prev: ResendOtpState, formData: FormData): Promise<ResendOtpState> {
  const supabase = await createClient();
  const email = normalizeSignupEmail(formData.get("email"));
  let alreadyConfirmed = false;

  try {
    const { error } = await supabase.auth.resend({ type: "signup", email });
    if (error) {
      const { data: { user } } = await supabase.auth.getUser();
      alreadyConfirmed = Boolean(user?.email_confirmed_at);
      if (!alreadyConfirmed) {
        logSignupVerificationFailure("resend_signup_otp", email, error);
        return { error: signupVerificationErrorMessage(error), sent: false };
      }
    }
  } catch (error) {
    const safeError = error instanceof Error ? error : new Error("Unknown resend failure");
    logSignupVerificationFailure("resend_signup_otp", email, safeError);
    return { error: signupVerificationErrorMessage(safeError), sent: false };
  }


  if (alreadyConfirmed) redirect("/onboarding");

  return { error: null, sent: true, sentAt: Date.now() };
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
