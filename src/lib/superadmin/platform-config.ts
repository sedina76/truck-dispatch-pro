import "server-only";
import { EMAIL_PROVIDER_CONFIGURED } from "@/lib/email/provider";

// Read-only "is the platform wired up" checks for Platform Console ->
// Settings. Reports only whether each setting is present (and, for Stripe,
// which mode the key is for, read from its public prefix). A secret value
// itself never leaves the server.

export type ConfigCheck = {
  label: string;
  state: "ok" | "warn" | "missing";
  value: string;
  help: string;
};

export function stripeKeyMode(key: string | undefined): "live" | "test" | "missing" | "unknown" {
  if (!key) return "missing";
  if (/^(sk|rk)_live_/.test(key)) return "live";
  if (/^(sk|rk)_test_/.test(key)) return "test";
  return "unknown";
}

export function getPlatformConfigChecks(env: Record<string, string | undefined> = process.env): ConfigCheck[] {
  const mode = stripeKeyMode(env.STRIPE_SECRET_KEY);
  const site = env.NEXT_PUBLIC_SITE_URL ?? "";
  return [
    {
      label: "Stripe payments",
      state: mode === "live" ? "ok" : mode === "missing" ? "missing" : "warn",
      value: mode === "live" ? "Live mode" : mode === "test" ? "Test mode" : mode === "missing" ? "Not set" : "Unrecognized key",
      help:
        mode === "live"
          ? "Real charges. The plan prices in the database must be live-mode prices too."
          : mode === "test"
            ? "Test mode: checkout works but no real money is collected."
            : "STRIPE_SECRET_KEY in Vercel. Without it, nobody can start a subscription.",
    },
    {
      label: "Stripe webhook",
      state: env.STRIPE_WEBHOOK_SECRET ? "ok" : "missing",
      value: env.STRIPE_WEBHOOK_SECRET ? "Signing secret set" : "Not set",
      help: "Stripe tells the site when a trial or payment starts. Endpoint: /api/webhooks/stripe. Set STRIPE_WEBHOOK_SECRET in Vercel.",
    },
    {
      label: "Outgoing email",
      state: EMAIL_PROVIDER_CONFIGURED || (env.RESEND_API_KEY && env.EMAIL_FROM) ? "ok" : "missing",
      value: EMAIL_PROVIDER_CONFIGURED || (env.RESEND_API_KEY && env.EMAIL_FROM) ? `From ${env.EMAIL_FROM ?? "configured sender"}` : "Not set",
      help: "Invoices, statements and settlements are emailed through Resend (RESEND_API_KEY and EMAIL_FROM).",
    },
    {
      label: "Site address",
      state: site.startsWith("https://") ? "ok" : site ? "warn" : "missing",
      value: site || "Not set",
      help: "NEXT_PUBLIC_SITE_URL. Password-reset and email-change links point here.",
    },
  ];
}
