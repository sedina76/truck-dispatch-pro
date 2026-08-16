import "server-only";
import { Resend } from "resend";
import { EMAIL_PROVIDER_CONFIGURED } from "@/lib/email/provider";

export type TestResult = { ok: true; message: string; accountLabel: string } | { ok: false; message: string; errorCode: string | null };

// Real, safe, side-effect-free test: resend.domains.list() is a read-only
// authenticated call -- it fails with an auth error on a bad API key (so
// this genuinely validates the credential), and its response tells us
// whether EMAIL_FROM's own domain is verified, which is the thing that
// actually determines whether sends will work. Never sends a real email
// just to "test" (spec section 22: no unnecessary side effects), never
// returns the API key itself.
export async function testResendConnection(): Promise<TestResult> {
  if (!EMAIL_PROVIDER_CONFIGURED) {
    return { ok: false, message: "RESEND_API_KEY and/or EMAIL_FROM are not set.", errorCode: "NOT_CONFIGURED" };
  }

  const fromHeader = process.env.EMAIL_FROM!;
  const emailMatch = fromHeader.match(/<([^>]+)>/);
  const fromAddress = emailMatch ? emailMatch[1] : fromHeader;
  const fromDomain = fromAddress.split("@")[1]?.toLowerCase();

  try {
    const resend = new Resend(process.env.RESEND_API_KEY);
    const { data, error } = await resend.domains.list();

    if (error) {
      return { ok: false, message: translateResendError(error.message), errorCode: error.name ?? "PROVIDER_ERROR" };
    }

    const domains = data?.data ?? [];
    const matched = fromDomain ? domains.find((d) => d.name.toLowerCase() === fromDomain) : null;

    if (fromDomain && !matched) {
      return { ok: false, message: `The API key is valid, but no domain matching "${fromDomain}" (from EMAIL_FROM) was found in this Resend account.`, errorCode: "DOMAIN_NOT_FOUND" };
    }
    if (matched && matched.status !== "verified") {
      return { ok: false, message: `Domain "${matched.name}" is not verified yet (status: ${matched.status}). Emails may fail or be filtered until DNS verification completes.`, errorCode: "DOMAIN_NOT_VERIFIED" };
    }

    return { ok: true, message: `Connected. Sending domain "${fromDomain}" is verified.`, accountLabel: fromAddress };
  } catch (err) {
    return { ok: false, message: err instanceof Error ? translateResendError(err.message) : "Could not reach Resend.", errorCode: "NETWORK_ERROR" };
  }
}

function translateResendError(raw: string): string {
  const lower = raw.toLowerCase();
  if (lower.includes("api key is invalid") || lower.includes("unauthorized")) return "The configured API key is invalid.";
  if (lower.includes("rate limit")) return "Resend rate limit reached -- try again shortly.";
  return "Resend could not be reached. Please try again.";
}
