// PHASE D.2.8 -- unit tests for the billing page's pure eligibility + copy
// helpers. No React, no Supabase, no Stripe. Run with the repo `npm test`
// (node --test).

import test from "node:test";
import assert from "node:assert/strict";
import {
  evaluateCheckoutGate,
  checkoutReturnNotice,
  toSellablePlanCards,
  refusalMessage,
  formatUsd,
  annualMonthlyEquivalent,
  SELLABLE_TIERS,
} from "./billing-view.ts";

// --------------------------------------------------------------------------
// evaluateCheckoutGate
// --------------------------------------------------------------------------
test("gate: billing-required incomplete org, owner/admin -> CTA shows", () => {
  const g = evaluateCheckoutGate({
    billingRequired: true,
    grandfatheredAt: null,
    status: "incomplete",
    isOwnerOrAdmin: true,
  });
  assert.deepEqual(g, { canCheckout: true, reason: "eligible" });
});

test("gate: canceled status is also eligible", () => {
  assert.equal(
    evaluateCheckoutGate({ billingRequired: true, grandfatheredAt: null, status: "canceled", isOwnerOrAdmin: true }).canCheckout,
    true
  );
});

test("gate: no subscription row yet -> eligible (checkout.ts creates the row)", () => {
  assert.deepEqual(
    evaluateCheckoutGate({ billingRequired: true, grandfatheredAt: null, status: null, isOwnerOrAdmin: true }),
    { canCheckout: true, reason: "no_subscription_row" }
  );
});

test("gate: grandfathered org NEVER gets a CTA (even owner, even billing_required)", () => {
  const g = evaluateCheckoutGate({
    billingRequired: true,
    grandfatheredAt: "2026-09-02T19:32:02Z",
    status: "active",
    isOwnerOrAdmin: true,
  });
  assert.deepEqual(g, { canCheckout: false, reason: "grandfathered" });
});

test("gate: non-owner/admin cannot initiate", () => {
  const g = evaluateCheckoutGate({
    billingRequired: true,
    grandfatheredAt: null,
    status: "incomplete",
    isOwnerOrAdmin: false,
  });
  assert.deepEqual(g, { canCheckout: false, reason: "not_authorized" });
});

test("gate: billing_not_required org gets no CTA", () => {
  assert.deepEqual(
    evaluateCheckoutGate({ billingRequired: false, grandfatheredAt: null, status: "incomplete", isOwnerOrAdmin: true }),
    { canCheckout: false, reason: "billing_not_required" }
  );
});

test("gate: live/dunning statuses block a NEW checkout", () => {
  for (const status of ["active", "trialing", "past_due", "unpaid", "paused"]) {
    const g = evaluateCheckoutGate({ billingRequired: true, grandfatheredAt: null, status, isOwnerOrAdmin: true });
    assert.deepEqual(g, { canCheckout: false, reason: "existing_subscription" }, status);
  }
});

test("gate: an unrecognized status fails closed (no CTA)", () => {
  assert.deepEqual(
    evaluateCheckoutGate({ billingRequired: true, grandfatheredAt: null, status: "some_future_status", isOwnerOrAdmin: true }),
    { canCheckout: false, reason: "unknown_status" }
  );
});

// --------------------------------------------------------------------------
// checkoutReturnNotice -- browser redirect is NON-authoritative
// --------------------------------------------------------------------------
test("return notice: ?checkout=complete with status still incomplete -> 'confirming', NOT 'activated'", () => {
  const n = checkoutReturnNotice("complete", "incomplete");
  assert.equal(n.tone, "info");
  assert.match(n.title, /confirming your subscription/i);
  assert.doesNotMatch(n.title + n.body, /activated|is active/i);
});

test("return notice: ?checkout=complete only claims active when DB already says trialing/active", () => {
  for (const s of ["trialing", "active"]) {
    const n = checkoutReturnNotice("complete", s);
    assert.equal(n.tone, "positive");
    assert.match(n.body, /active/i);
  }
});

test("return notice: ?checkout=canceled implies no state change", () => {
  const n = checkoutReturnNotice("canceled", "incomplete");
  assert.equal(n.tone, "neutral");
  assert.match(n.body, /no changes were made/i);
});

test("return notice: no/unknown param -> nothing", () => {
  assert.equal(checkoutReturnNotice(undefined, "incomplete"), null);
  assert.equal(checkoutReturnNotice("", "incomplete"), null);
  assert.equal(checkoutReturnNotice("bogus", "active"), null);
});

// --------------------------------------------------------------------------
// toSellablePlanCards
// --------------------------------------------------------------------------
const RAW_PLANS = [
  { tier: "starter", name: "Starter", monthly_price_cents: 4900, annual_price_cents: 49000, description: "x", features: [], is_public: false, is_active: false },
  { tier: "pro", name: "Pro", monthly_price_cents: 9900, annual_price_cents: 99000, description: "Pro plan", features: ["A", "B"], is_public: true, is_active: true },
  { tier: "essential", name: "Essential", monthly_price_cents: 5900, annual_price_cents: 59000, description: "Essential plan", features: ["A"], is_public: true, is_active: true },
  { tier: "enterprise", name: "Enterprise", monthly_price_cents: 39900, annual_price_cents: 399000, description: "x", features: [], is_public: false, is_active: true },
];

test("plan cards: only public+active sellable tiers, Essential before Pro", () => {
  const cards = toSellablePlanCards(RAW_PLANS);
  assert.deepEqual(cards.map((c) => c.tier), ["essential", "pro"]);
  assert.equal(cards[0].monthlyCents, 5900);
  assert.equal(cards[1].annualCents, 99000);
  assert.deepEqual(cards[1].features, ["A", "B"]);
});

test("plan cards: no Stripe Price IDs are ever carried to the client model", () => {
  const withPrices = RAW_PLANS.map((p) => ({ ...p, stripe_price_id_monthly: "price_x", stripe_price_id_annual: "price_y" }));
  const cards = toSellablePlanCards(withPrices);
  for (const c of cards) {
    assert.equal(JSON.stringify(c).includes("price_"), false);
  }
});

test("plan cards: SELLABLE_TIERS is exactly essential + pro", () => {
  assert.deepEqual([...SELLABLE_TIERS], ["essential", "pro"]);
});

// --------------------------------------------------------------------------
// refusalMessage
// --------------------------------------------------------------------------
test("refusalMessage: prefers the server-provided safe message", () => {
  assert.equal(refusalMessage("stripe_error", "Server said this."), "Server said this.");
});

test("refusalMessage: falls back to safe per-code copy, then a generic line", () => {
  assert.match(refusalMessage("checkout_in_progress", null), /already in progress/i);
  assert.match(refusalMessage("grandfathered", ""), /legacy billing access/i);
  assert.match(refusalMessage("some_unmapped_code", undefined), /something went wrong/i);
});

test("refusalMessage: never returns an empty string", () => {
  for (const c of [undefined, "", "x", "internal_error"]) {
    assert.ok(refusalMessage(c, "").length > 0);
  }
});

// --------------------------------------------------------------------------
// currency formatting
// --------------------------------------------------------------------------
test("formatUsd: whole dollars have no cents; fractional keeps 2dp", () => {
  assert.equal(formatUsd(5900), "$59");
  assert.equal(formatUsd(59000), "$590");
  assert.equal(formatUsd(9900), "$99");
  assert.equal(formatUsd(4917), "$49.17");
});

test("annualMonthlyEquivalent: yearly price / 12, rounded to cents", () => {
  assert.equal(annualMonthlyEquivalent(59000), "$49.17"); // 59000/12 = 4916.67 -> 4917c
  assert.equal(annualMonthlyEquivalent(99000), "$82.50"); // 99000/12 = 8250c
  assert.equal(annualMonthlyEquivalent(120000), "$100"); // exact -> whole dollars
});
