// PHASE D.2.9 -- source assertions proving the ACTIVE self-service billing
// path uses the FINAL product policy: a 30-day free trial that needs NO card
// to start, failing closed at trial end.
//
// checkout.ts / checkout-cta.tsx pull in "server-only", "@/..." aliases,
// next/*, and the Stripe SDK, so they cannot be imported under `node --test`.
// This file reads them as source text (the same technique middleware.test.mjs
// uses on route.ts) and asserts the request shape + UI copy directly.
// middleware.ts is read the same way to check the access resolver.
//
// ZERO Stripe calls. ZERO DB. ZERO network.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolveBillingAccess } from "../../../../lib/billing/access-policy.ts";

const CHECKOUT = readFileSync(new URL("../../../../lib/stripe/checkout.ts", import.meta.url), "utf8");
const CTA = readFileSync(new URL("./checkout-cta.tsx", import.meta.url), "utf8");
const MIDDLEWARE = readFileSync(new URL("../../../../lib/supabase/middleware.ts", import.meta.url), "utf8");

// Comments in checkout.ts legitimately mention the OLD contract to explain
// the change; strip full-line `//` comments so the assertions look at
// executable code only.
const CHECKOUT_CODE = CHECKOUT.replace(/^[ \t]*\/\/.*$/gm, "");
const CTA_CODE = CTA.replace(/^[ \t]*\/\/.*$/gm, "");

// ==========================================================================
// 1. authoritative trial duration is 30 days, server-side, single constant
// ==========================================================================
test("D.2.9 #1: TRIAL_PERIOD_DAYS is 30 (one authoritative server constant)", () => {
  assert.match(CHECKOUT_CODE, /const\s+TRIAL_PERIOD_DAYS\s*=\s*30\s*;/, "TRIAL_PERIOD_DAYS = 30");
  assert.doesNotMatch(CHECKOUT_CODE, /TRIAL_PERIOD_DAYS\s*=\s*14\b/, "no 14-day constant remains");
  // exactly one assignment
  const assigns = [...CHECKOUT_CODE.matchAll(/TRIAL_PERIOD_DAYS\s*=/g)];
  assert.equal(assigns.length, 1, "TRIAL_PERIOD_DAYS assigned exactly once");
});

test("D.2.9 #1b: the Checkout request derives its trial length from that constant, not a literal", () => {
  assert.match(
    CHECKOUT_CODE.replace(/\s+/g, " "),
    /trial_period_days:\s*TRIAL_PERIOD_DAYS/,
    "subscription_data.trial_period_days: TRIAL_PERIOD_DAYS"
  );
  assert.doesNotMatch(CHECKOUT_CODE, /trial_period_days:\s*\d/, "no numeric literal trial length");
});

test("D.2.9 #1c: the browser cannot choose or override the trial length", () => {
  // createSubscriptionCheckout only accepts { organizationId, actorUserId,
  // tier, billingCycle } -- no trial field. Prove no trial value is read
  // from an argument / request object.
  assert.doesNotMatch(CHECKOUT_CODE, /trial[_A-Za-z]*\s*[:=][^;]*\b(input|params|args|body|req|request)\b/i);
});

// ==========================================================================
// 2. Checkout is subscription mode
// ==========================================================================
test("D.2.9 #2: Checkout Session mode is 'subscription'", () => {
  assert.match(CHECKOUT_CODE.replace(/\s+/g, " "), /mode:\s*"subscription"/);
});

// ==========================================================================
// 3 & 4. no card required to START; correct payment_method_collection
// ==========================================================================
test("D.2.9 #3/#4: payment_method_collection is 'if_required' (cardless trial start), never 'always'", () => {
  const flat = CHECKOUT_CODE.replace(/\s+/g, " ");
  assert.match(flat, /payment_method_collection:\s*"if_required"/, "if_required");
  assert.doesNotMatch(flat, /payment_method_collection:\s*"always"/, "no 'always' remains in active code");
});

// ==========================================================================
// 5. missing-payment-method trial-end behavior fails closed
// ==========================================================================
test("D.2.9 #5: trial_settings.end_behavior.missing_payment_method is 'cancel' (fail closed)", () => {
  const flat = CHECKOUT_CODE.replace(/\s+/g, " ");
  assert.match(flat, /trial_settings:\s*\{\s*end_behavior:\s*\{\s*missing_payment_method:\s*"cancel"\s*\}\s*\}/);
  // never a non-fail-closed alternative
  assert.doesNotMatch(flat, /missing_payment_method:\s*"(create_invoice|pause)"/);
});

// ==========================================================================
// 6-10. server-resolved Price; no client Price ID / org identity; customer
//        reuse + deterministic idempotency key unchanged
// ==========================================================================
test("D.2.9 #6-9: line item Price is the server-resolved frozenPriceId, qty 1 -- same for every tier/cycle", () => {
  const flat = CHECKOUT_CODE.replace(/\s+/g, " ");
  assert.match(flat, /line_items:\s*\[\s*\{\s*price:\s*frozenPriceId,\s*quantity:\s*1\s*\}\s*\]/);
  // frozenPriceId comes from priceForCycle(frozenPlan, frozenCycle) -- DB, not input
  assert.match(CHECKOUT_CODE, /frozenPriceId\s*=\s*priceForCycle\(frozenPlan,\s*frozenCycle\)/);
});

test("D.2.9 #10: existing Stripe Customer is reused via resolveStripeCustomerForOrg(existingCustomerId)", () => {
  assert.match(CHECKOUT_CODE, /resolveStripeCustomerForOrg\(/);
  assert.match(CHECKOUT_CODE, /existingCustomerId:\s*ensured\.row\.stripe_customer_id/);
  // customer.ts fast-path: a stored mapping short-circuits before any create
  const CUSTOMER = readFileSync(new URL("../../../../lib/stripe/customer.ts", import.meta.url), "utf8");
  assert.match(
    CUSTOMER.replace(/\s+/g, " "),
    /if \(existingCustomerId && existingCustomerId\.trim\(\) !== ""\) \{ return \{ ok: true, customerId: existingCustomerId\.trim\(\), created: false \}; \}/
  );
});

test("D.2.9 #11: idempotency key = prefix + row id + IMMUTABLE attempt id (no price, no timestamp)", () => {
  assert.match(
    CHECKOUT_CODE.replace(/\s+/g, " "),
    /idempotencyKey = `\$\{CHECKOUT_IDEMPOTENCY_PREFIX\}\$\{rowId\}_\$\{attemptId\}`/
  );
});

test("D.2.9 #12: replacing an expired Session mints a NEW attempt id (randomUUID) via the triple-null CAS", () => {
  // expired -> { kind: "replace" }
  assert.match(CHECKOUT_CODE.replace(/\s+/g, " "), /session\.status === "expired"\) return \{ kind: "replace" \}/);
  // 8c claim: randomUUID + CAS requiring all three columns still null
  assert.match(CHECKOUT_CODE, /const newAttemptId = randomUUID\(\);/);
  const flat = CHECKOUT_CODE.replace(/\s+/g, " ");
  assert.match(flat, /\.is\("stripe_checkout_session_id", null\) \.is\("stripe_checkout_attempt_id", null\) \.is\("checkout_pending_since", null\)/);
});

// ==========================================================================
// 13. browser success redirect stays non-authoritative
// ==========================================================================
test("D.2.9 #13: the CTA never sets a local trialing/active status; success path is a redirect only", () => {
  assert.doesNotMatch(CTA_CODE, /status\s*[:=]\s*["'`]?(trialing|active)/i);
  // only outcomes are: external redirect, router.refresh(), or an error string
  assert.match(CTA_CODE, /window\.location\.assign\(result\.url\)/);
  assert.match(CTA_CODE, /router\.refresh\(\)/);
});

// ==========================================================================
// 14 & 15. access resolver (D.2.10): trialing = full access; incomplete = not.
// The authoritative policy now lives in src/lib/billing/access-policy.ts and
// is exercised directly in access-policy.test.mjs; here we just confirm the
// D.2.9 trial states resolve as the trial design requires.
// ==========================================================================
test("D.2.9 #14: a trialing billing-required org resolves to FULL access", () => {
  const r = resolveBillingAccess({
    billingRequired: true,
    subscriptionExists: true,
    grandfatheredAt: null,
    status: "trialing",
    pastDueSince: null,
    now: new Date("2026-09-07T12:00:00Z"),
  });
  assert.deepEqual(r, { access: "full", reason: "status_trialing" });
});

test("D.2.9 #15: an incomplete billing-required org resolves to BILLING_ONLY, and middleware redirects it to /settings/subscription", () => {
  const r = resolveBillingAccess({
    billingRequired: true,
    subscriptionExists: true,
    grandfatheredAt: null,
    status: "incomplete",
    pastDueSince: null,
    now: new Date("2026-09-07T12:00:00Z"),
  });
  assert.deepEqual(r, { access: "billing_only", reason: "status_incomplete" });
  assert.match(MIDDLEWARE, /SUBSCRIPTION_GATE_EXEMPT_PATHS\s*=\s*\[[^\]]*"\/settings\/subscription"/s);
  assert.match(
    MIDDLEWARE.replace(/\s+/g, " "),
    /decision\.access === "billing_only"\) \{ .*blockedUrl\.pathname = "\/settings\/subscription"/
  );
});

// ==========================================================================
// 16 & 17. covered in full by billing-view.test.mjs (evaluateCheckoutGate):
//   grandfathered -> no CTA ; non-owner/admin -> no CTA. Re-assert the gate
//   is what the page uses, so this file fails if that wiring is removed.
// ==========================================================================
test("D.2.9 #16/#17: the page gates the CTA through evaluateCheckoutGate(...canCheckout)", () => {
  const PAGE = readFileSync(new URL("./page.tsx", import.meta.url), "utf8");
  assert.match(PAGE, /evaluateCheckoutGate\(\{/);
  assert.match(PAGE, /gate\.canCheckout && planCards\.length > 0 \?/);
});

// ==========================================================================
// 18-21. UI copy
// ==========================================================================
test("D.2.9 #18: active UI says 'Start 30-Day Free Trial'", () => {
  assert.match(CTA, /Start 30-Day Free Trial/);
});

test("D.2.9 #19: active UI says a card is not required", () => {
  assert.match(CTA, /No credit card required/);
  assert.match(CTA, /No credit card is required to start/);
});

test("D.2.9 #20: active UI contains NO 'Start 14-Day Trial'", () => {
  assert.doesNotMatch(CTA, /Start 14-Day Trial/);
  assert.doesNotMatch(CTA, /14-day trial/i);
  assert.doesNotMatch(CTA, /14-Day Trial/);
});

test("D.2.9 #21: active UI contains NO obsolete 'card is not charged during the 14-day trial'", () => {
  assert.doesNotMatch(CTA, /card is not charged/i);
  assert.doesNotMatch(CTA, /Your card is not/i);
});

// ==========================================================================
// 22. cardless trial does not reach freight accounting / QuickBooks
// ==========================================================================
test("D.2.9 #22: the webhook runtime touches only organization_subscriptions + the four SaaS RPCs", () => {
  const SUB = readFileSync(new URL("../../../../lib/stripe/subscription-state.ts", import.meta.url), "utf8");
  const froms = [...SUB.matchAll(/\.from\("([^"]+)"\)/g)].map((x) => x[1]);
  assert.deepEqual([...new Set(froms)], ["organization_subscriptions"], "only organization_subscriptions is read/written");
  const rpcs = [...SUB.matchAll(/\.rpc\("([^"]+)"/g)].map((x) => x[1]).sort();
  assert.deepEqual(
    [...new Set(rpcs)],
    ["apply_stripe_subscription_state", "claim_stripe_webhook_event", "complete_stripe_webhook_event", "fail_stripe_webhook_event"].sort()
  );
  for (const forbidden of [/quickbooks/i, /"payments"/, /"settlements"/, /"driver_settlements"/, /factoring/i, /"advances"/]) {
    assert.doesNotMatch(SUB, forbidden, `webhook runtime must not reference ${forbidden}`);
  }
});
