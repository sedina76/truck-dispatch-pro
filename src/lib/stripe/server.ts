import "server-only";
import Stripe from "stripe";

// Server-only Stripe API client for Truck Dispatch Pro's OWN SaaS
// subscription billing (Stripe = our subscription revenue). This is a
// different system from the tenant QuickBooks accounting integration
// (0116-0118) and from freight invoices/payments -- never share
// credentials or helpers across them beyond provider-neutral patterns.
//
// Never import this module from client ("use client") code. The
// `import "server-only"` above turns any client import into a build
// error -- the same guard `src/lib/supabase/service-role.ts` uses.
//
// LAZY on purpose: the client is constructed on the FIRST getStripe()
// call, not at module import. So merely importing this file (via a
// shared server util, a barrel, etc.) never requires STRIPE_SECRET_KEY
// to be set -- only a code path that actually talks to Stripe does.
// `next build` / RSC render of unrelated pages stay unaffected.
//
// API VERSION: intentionally NOT pinned here. The installed `stripe`
// package (see package.json) is built against exactly one Stripe API
// version and ships the matching TypeScript types; omitting `apiVersion`
// makes the SDK send that release-pinned version, so runtime responses
// and compile-time types can never drift apart. To adopt a newer Stripe
// API version, bump the `stripe` dependency (a reviewed change) rather
// than hardcoding a version string here.
//
// This module CONSTRUCTS the client only. It performs NO Stripe API
// request. Checkout Sessions, Customers, Subscriptions, the Customer
// Portal, and webhook signature verification all live in later,
// separately-reviewed phases.
//
// STRIPE_WEBHOOK_SECRET is deliberately NOT read here. Webhook signature
// verification is a distinct credential and a distinct (future) code
// path; it must never be passed to the Stripe constructor.

let client: Stripe | null = null;

/**
 * The server-side Stripe API client (singleton per server process).
 *
 * Throws a clear error -- WITHOUT ever including the key's value -- when
 * STRIPE_SECRET_KEY is unset/blank, or when a live-mode key is supplied
 * while the integration is still in its sandbox phase. Test/sandbox
 * secret keys look like `sk_test_...` (or `rk_test_...` for a restricted
 * key); any non-live key is accepted (no length or exact-prefix
 * requirement).
 *
 * Server-only. Do not import from client code.
 */
export function getStripe(): Stripe {
  if (client) return client;

  const secretKey = process.env.STRIPE_SECRET_KEY;
  if (!secretKey || secretKey.trim() === "") {
    throw new Error(
      "STRIPE_SECRET_KEY is not configured. Set it (server-only, never NEXT_PUBLIC_*) " +
        "before any code path talks to Stripe. Test/sandbox keys look like 'sk_test_...'."
    );
  }
  if (secretKey.startsWith("sk_live_") || secretKey.startsWith("rk_live_")) {
    throw new Error(
      "A live-mode Stripe secret key is configured, but Truck Dispatch Pro billing " +
        "is still in its sandbox phase. Use a test-mode key ('sk_test_...')."
    );
  }

  client = new Stripe(secretKey, {
    // Descriptive only -- lets Stripe attribute API traffic to this
    // integration in the Dashboard. No behavior change.
    appInfo: { name: "Truck Dispatch Pro" },
  });
  return client;
}
