import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  AMBIGUOUS_OTP_MESSAGE,
  normalizeSignupEmail,
  signupVerificationErrorMessage,
} from "./signup-verification.ts";

const ACTIONS = readFileSync(new URL("../supabase/actions.ts", import.meta.url), "utf8");
const FORM = readFileSync(
  new URL("../../app/(auth)/verify-email/verify-email-form.tsx", import.meta.url),
  "utf8"
);
const PROFILE_MIGRATION = readFileSync(
  new URL("../../../supabase/migrations/0009_functions_triggers.sql", import.meta.url),
  "utf8"
);
const ORG_MIGRATION = readFileSync(
  new URL("../../../supabase/migrations/0012_profile_privilege_guard.sql", import.meta.url),
  "utf8"
);

test("signup, verification, and resend share trim+lowercase normalization", () => {
  assert.equal(normalizeSignupEmail("  Subscriber@Example.COM "), "subscriber@example.com");
  assert.equal((ACTIONS.match(/normalizeSignupEmail\(formData\.get\("email"\)\)/g) ?? []).length, 3);
});

test("fresh valid and leading-zero codes stay strings in the signup verification request", () => {
  assert.match(ACTIONS, /const token = String\(formData\.get\("token"\) \|\| ""\)/);
  assert.match(ACTIONS, /verifyOtp\(\{ email, token, type: "signup" \}\)/);
  assert.doesNotMatch(ACTIONS, /(?:Number|parseInt|parseFloat)\s*\(\s*token/);
  assert.equal(/^\d{6}$/.test("012345"), true);
  assert.match(ACTIONS, /if \(error\)[\s\S]*redirect\("\/onboarding"\);/);
});

test("ambiguous Supabase invalid/expired response is not labeled definitely expired", () => {
  assert.equal(
    signupVerificationErrorMessage({ code: "otp_expired", status: 403, message: "Token has expired or is invalid" }),
    AMBIGUOUS_OTP_MESSAGE
  );
});

test("rate limiting has retry-specific copy", () => {
  assert.equal(
    signupVerificationErrorMessage({ code: "over_request_rate_limit", status: 429, message: "Too many requests" }),
    "Too many verification attempts. Please wait and try again."
  );
});

test("network and server failures use the safe retry message", () => {
  const expected = "Verification could not be completed. Please try again.";
  assert.equal(signupVerificationErrorMessage({ name: "AuthRetryableFetchError", message: "fetch failed" }), expected);
  assert.equal(signupVerificationErrorMessage({ code: "unexpected_failure", status: 503, message: "backend unavailable" }), expected);
});

test("successful resend clears the old code, focuses the OTP input, and explains newest-code semantics", () => {
  assert.match(FORM, /if \(!resendState\.sentAt\) return;[\s\S]*setOtp\(""\)/);
  assert.match(FORM, /getElementById\("signup-verification-code"\)\?\.focus\(\)/);
  assert.match(FORM, /A new code was sent\. Your previous code is no longer valid—enter only the newest code\./);
});

test("repeated Verify clicks are synchronously reduced to one submission", () => {
  assert.match(FORM, /const verifySubmitting = useRef\(false\)/);
  assert.match(FORM, /if \(verifySubmitting\.current \|\| verifyPending\) event\.preventDefault\(\)/);
  assert.match(FORM, /else verifySubmitting\.current = true/);
  assert.match(FORM, /disabled=\{verifyPending \|\| otp\.length !== SIGNUP_OTP_LENGTH\}/);
});

test("already-confirmed verification continues through guarded onboarding without provisioning duplicates", () => {
  assert.match(ACTIONS, /if \(!user\?\.email_confirmed_at\)[\s\S]*return \{ error: signupVerificationErrorMessage\(error\) \}/);
  assert.match(ACTIONS, /redirect\("\/onboarding"\)/);
  assert.match(PROFILE_MIGRATION, /after insert on auth\.users/);
  assert.match(PROFILE_MIGRATION, /insert into public\.profiles/);
  assert.match(ORG_MIGRATION, /if exists \(select 1 from public\.profiles where id = auth\.uid\(\) and organization_id is not null\)/);
  assert.doesNotMatch(ACTIONS.slice(ACTIONS.indexOf("export async function verifySignupOtp")), /organization_subscriptions|trial_end|stripe/);
});

test("failed-verification diagnostics contain metadata and never the OTP or full email", () => {
  const logger = ACTIONS.slice(ACTIONS.indexOf("function logSignupVerificationFailure"), ACTIONS.indexOf("export async function verifySignupOtp"));
  assert.match(logger, /operation/);
  assert.match(logger, /verificationType: "signup"/);
  assert.match(logger, /errorCode/);
  assert.match(logger, /httpStatus/);
  assert.match(logger, /createHash\("sha256"\)/);
  assert.doesNotMatch(logger, /\btoken\b|password|access_token|refresh_token/);
  assert.doesNotMatch(logger, /console\.error\([^)]*email[,)]/s);
});
