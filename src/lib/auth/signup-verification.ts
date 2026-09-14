export const AMBIGUOUS_OTP_MESSAGE =
  "This verification code is invalid or has expired. Request a new code and enter only the newest one.";

export type SupabaseAuthErrorLike = {
  code?: string;
  message?: string;
  status?: number;
  name?: string;
};

export function normalizeSignupEmail(value: unknown): string {
  return String(value ?? "").trim().toLowerCase();
}

export function signupVerificationErrorMessage(error: SupabaseAuthErrorLike): string {
  const code = (error.code ?? "").toLowerCase();
  const message = (error.message ?? "").toLowerCase();
  const status = error.status;

  if (
    code === "over_email_send_rate_limit" ||
    code === "over_request_rate_limit" ||
    code === "too_many_requests" ||
    status === 429 ||
    message.includes("rate limit") ||
    message.includes("too many requests") ||
    message.includes("for security purposes")
  ) {
    return "Too many verification attempts. Please wait and try again.";
  }

  // Supabase currently uses otp_expired with the combined provider message
  // "Token has expired or is invalid" for either a stale or mismatched OTP.
  // Never claim one cause when the backend did not distinguish it.
  if (
    code === "otp_expired" ||
    code === "otp_invalid" ||
    code === "invalid_token" ||
    message.includes("token has expired or is invalid") ||
    message.includes("invalid otp") ||
    message.includes("invalid token")
  ) {
    return AMBIGUOUS_OTP_MESSAGE;
  }

  if (
    status === undefined ||
    status >= 500 ||
    error.name === "AuthRetryableFetchError" ||
    message.includes("fetch failed") ||
    message.includes("network")
  ) {
    return "Verification could not be completed. Please try again.";
  }

  return "Verification could not be completed. Please try again.";
}
