import { NextResponse } from "next/server";
import { getStripe } from "@/lib/stripe/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import {
  preflightWebhookRequest,
  processStripeEvent,
  type MinimalEvent,
  type StripeSyncApi,
  type StripeSyncDb,
} from "@/lib/stripe/subscription-state";

// PHASE D.2 -- the ONE signed Stripe SaaS-billing webhook endpoint.
//
// MIDDLEWARE (done, D.2.2): "/api/webhooks/stripe" is in PUBLIC_PATHS in
// src/lib/supabase/middleware.ts -- EXACTLY as "/api/webhooks/resend" is --
// so an unauthenticated Stripe delivery reaches this handler instead of
// being 307-redirected to /login. "Public" there means only "the request
// may reach this route", never "trusted": every check in the SEQUENCE
// below still runs before any DB work.
//
// SEQUENCE (section A):
//   1. STRIPE_WEBHOOK_SECRET present?         no -> 503, ZERO DB work
//   2. raw body via req.text()               (never req.json())
//   3. Stripe-Signature header present?       no -> 400, ZERO DB work
//   4. stripe.webhooks.constructEvent(raw, sig, secret)
//                                            throws -> 400, ZERO DB work
//   5. ONLY THEN -> processStripeEvent(...)  (claim, canonical retrieve,
//                                             atomic 0127 RPC)
//
// No JSON of the body is parsed or trusted before step 4 succeeds.
// STRIPE_WEBHOOK_SECRET is read here server-side only, never logged, never
// returned, never NEXT_PUBLIC_*.

export const runtime = "nodejs"; // Stripe signature verification needs Node crypto.

export async function POST(req: Request): Promise<Response> {
  const secret = process.env.STRIPE_WEBHOOK_SECRET;
  const signature = req.headers.get("stripe-signature");

  const pre = preflightWebhookRequest({ secret, signature });
  if (!pre.ok) {
    if (pre.error === "webhook_not_configured") {
      console.error("[stripe-webhook] STRIPE_WEBHOOK_SECRET is not configured -- rejecting webhook.");
    }
    return NextResponse.json({ error: pre.error }, { status: pre.status });
  }
  // preflightWebhookRequest guarantees both are non-empty strings here.
  const webhookSecret: string = secret as string;
  const stripeSignature: string = signature as string;

  // Raw body -- read AFTER the config/signature-header preflight, still
  // before any parsing or trust of its contents.
  const rawBody = await req.text();

  let stripe: ReturnType<typeof getStripe>;
  try {
    stripe = getStripe();
  } catch (err) {
    console.error("[stripe-webhook] Stripe client unavailable:", err instanceof Error ? err.message : "unknown");
    return NextResponse.json({ error: "Webhook not configured." }, { status: 503 });
  }

  let event: MinimalEvent;
  try {
    // Verification happens HERE, on the raw body, before any application
    // field of the payload is trusted for anything.
    event = stripe.webhooks.constructEvent(rawBody, stripeSignature, webhookSecret) as unknown as MinimalEvent;
  } catch (err) {
    // Signature invalid / malformed / stale -> reject. No DB mutation.
    console.warn("[stripe-webhook] signature verification failed:", err instanceof Error ? err.message : "unknown");
    return NextResponse.json({ error: "Invalid signature." }, { status: 400 });
  }

  const db = createServiceRoleClient() as unknown as StripeSyncDb;
  const outcome = await processStripeEvent(event, { stripe: stripe as unknown as StripeSyncApi, db });
  return NextResponse.json(outcome.body, { status: outcome.status });
}

// A GET (or any non-POST) to this endpoint is not a Stripe delivery.
export function GET(): Response {
  return NextResponse.json({ error: "Method Not Allowed." }, { status: 405 });
}
