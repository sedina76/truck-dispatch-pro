// PHASE D.2.10 -- unit tests for the authoritative billing access resolver.
// Pure: no Stripe, no Supabase, no real clock. Run with `npm test`.

import test from "node:test";
import assert from "node:assert/strict";
import {
  resolveBillingAccess,
  PAST_DUE_GRACE_DAYS,
  PAST_DUE_GRACE_MS,
} from "./access-policy.ts";

const NOW = new Date("2026-09-07T12:00:00.000Z");

// Base = a billing-required, non-grandfathered org with a subscription row.
function facts(over = {}) {
  return {
    billingRequired: true,
    subscriptionExists: true,
    grandfatheredAt: null,
    status: "active",
    pastDueSince: null,
    now: NOW,
    ...over,
  };
}

// ==========================================================================
// billing_required = false  (0121 legacy / pre-billing orgs)
// ==========================================================================
test("#1 billing_required=false + no subscription -> full (billing_not_required)", () => {
  assert.deepEqual(
    resolveBillingAccess(facts({ billingRequired: false, subscriptionExists: false, status: null })),
    { access: "full", reason: "billing_not_required" }
  );
});

test("#2 billing_required=false + active legacy subscription -> full (exempt wins over status)", () => {
  assert.deepEqual(
    resolveBillingAccess(facts({ billingRequired: false, status: "active" })),
    { access: "full", reason: "billing_not_required" }
  );
});

test("#2b billing_required=false + a normally-blocking status (canceled) -> still full", () => {
  assert.equal(resolveBillingAccess(facts({ billingRequired: false, status: "canceled" })).access, "full");
});

// ==========================================================================
// billing_required = true  +  NO subscription row  -> FAIL CLOSED
// ==========================================================================
test("#3 billing_required=true + no subscription row -> billing_only (no_subscription)", () => {
  assert.deepEqual(
    resolveBillingAccess(facts({ subscriptionExists: false, status: null, grandfatheredAt: null })),
    { access: "billing_only", reason: "no_subscription" }
  );
});

// ==========================================================================
// status matrix (billing_required = true, non-grandfathered)
// ==========================================================================
test("#4 incomplete -> billing_only", () => {
  assert.deepEqual(resolveBillingAccess(facts({ status: "incomplete" })), {
    access: "billing_only",
    reason: "status_incomplete",
  });
});

test("#5 incomplete_expired -> billing_only (previously FAILED OPEN)", () => {
  assert.deepEqual(resolveBillingAccess(facts({ status: "incomplete_expired" })), {
    access: "billing_only",
    reason: "status_incomplete_expired",
  });
});

test("#6 trialing -> full", () => {
  assert.deepEqual(resolveBillingAccess(facts({ status: "trialing" })), {
    access: "full",
    reason: "status_trialing",
  });
});

test("#7 active -> full", () => {
  assert.deepEqual(resolveBillingAccess(facts({ status: "active" })), {
    access: "full",
    reason: "status_active",
  });
});

test("#8 unpaid -> billing_only (previously FAILED OPEN)", () => {
  assert.deepEqual(resolveBillingAccess(facts({ status: "unpaid" })), {
    access: "billing_only",
    reason: "status_unpaid",
  });
});

test("#9 paused -> billing_only", () => {
  assert.deepEqual(resolveBillingAccess(facts({ status: "paused" })), {
    access: "billing_only",
    reason: "status_paused",
  });
});

test("#10 canceled -> billing_only", () => {
  assert.deepEqual(resolveBillingAccess(facts({ status: "canceled" })), {
    access: "billing_only",
    reason: "status_canceled",
  });
});

// ==========================================================================
// 7-day past_due grace, boundary-exact
// ==========================================================================
const ANCHOR = new Date("2026-09-01T00:00:00.000Z");
const anchorIso = ANCHOR.toISOString();

test("PAST_DUE_GRACE constants: 7 days", () => {
  assert.equal(PAST_DUE_GRACE_DAYS, 7);
  assert.equal(PAST_DUE_GRACE_MS, 7 * 24 * 60 * 60 * 1000);
});

test("#11 past_due at grace start -> full (past_due_grace)", () => {
  assert.deepEqual(
    resolveBillingAccess(facts({ status: "past_due", pastDueSince: anchorIso, now: new Date(ANCHOR.getTime()) })),
    { access: "full", reason: "past_due_grace" }
  );
});

test("#12 past_due at 6d23h59m59s -> full", () => {
  const now = new Date(ANCHOR.getTime() + PAST_DUE_GRACE_MS - 1000);
  assert.equal(
    resolveBillingAccess(facts({ status: "past_due", pastDueSince: anchorIso, now })).access,
    "full"
  );
});

test("#13 past_due at EXACTLY anchor + 7 days -> billing_only (past_due_grace_expired)", () => {
  const now = new Date(ANCHOR.getTime() + PAST_DUE_GRACE_MS);
  assert.deepEqual(
    resolveBillingAccess(facts({ status: "past_due", pastDueSince: anchorIso, now })),
    { access: "billing_only", reason: "past_due_grace_expired" }
  );
});

test("#14 past_due at anchor + 7 days + 1ms -> billing_only", () => {
  const now = new Date(ANCHOR.getTime() + PAST_DUE_GRACE_MS + 1);
  assert.equal(
    resolveBillingAccess(facts({ status: "past_due", pastDueSince: anchorIso, now })).access,
    "billing_only"
  );
});

test("#15 past_due + NULL past_due_since -> billing_only (past_due_no_anchor), never infers now", () => {
  assert.deepEqual(
    resolveBillingAccess(facts({ status: "past_due", pastDueSince: null })),
    { access: "billing_only", reason: "past_due_no_anchor" }
  );
});

test("#15b past_due + unparseable past_due_since -> billing_only (past_due_no_anchor)", () => {
  assert.equal(
    resolveBillingAccess(facts({ status: "past_due", pastDueSince: "not-a-date" })).reason,
    "past_due_no_anchor"
  );
  assert.equal(
    resolveBillingAccess(facts({ status: "past_due", pastDueSince: "   " })).reason,
    "past_due_no_anchor"
  );
});

// ==========================================================================
// unknown / null status -> FAIL CLOSED
// ==========================================================================
test("#16 unknown status -> billing_only (status_unknown)", () => {
  assert.deepEqual(resolveBillingAccess(facts({ status: "past_due_forgiven" })), {
    access: "billing_only",
    reason: "status_unknown",
  });
  assert.equal(resolveBillingAccess(facts({ status: "" })).reason, "status_unknown");
});

test("#17 null status (row exists) -> billing_only (status_unknown)", () => {
  assert.deepEqual(resolveBillingAccess(facts({ status: null })), {
    access: "billing_only",
    reason: "status_unknown",
  });
});

// ==========================================================================
// grandfathered precedence
// ==========================================================================
test("#18 grandfathered row -> full regardless of status (even 'canceled')", () => {
  for (const status of ["canceled", "incomplete", "unpaid", "past_due", null, "weird"]) {
    assert.deepEqual(
      resolveBillingAccess(facts({ grandfatheredAt: "2026-09-02T19:32:02Z", status })),
      { access: "full", reason: "grandfathered" },
      `status=${status}`
    );
  }
});

test("#18b precedence: billing_required=false beats grandfathered_at (both -> full, exempt reason)", () => {
  assert.deepEqual(
    resolveBillingAccess(facts({ billingRequired: false, grandfatheredAt: "2026-09-02T19:32:02Z", status: "canceled" })),
    { access: "full", reason: "billing_not_required" }
  );
});

test("#18c grandfathered flag ignored when NO subscription row exists", () => {
  // grandfatheredAt comes off the row; if there's no row it is null anyway.
  assert.deepEqual(
    resolveBillingAccess(facts({ subscriptionExists: false, grandfatheredAt: null, status: null })),
    { access: "billing_only", reason: "no_subscription" }
  );
});

// ==========================================================================
// United Leather lifecycle (NOT special-cased -- plain facts)
// ==========================================================================
test("#19 United Leather now: billing_required=true, row exists, grandfathered_at=NULL, status=incomplete -> billing_only", () => {
  assert.deepEqual(
    resolveBillingAccess(facts({ status: "incomplete", grandfatheredAt: null })),
    { access: "billing_only", reason: "status_incomplete" }
  );
});

test("#20 United Leather after signed trial activation: status=trialing -> full", () => {
  assert.deepEqual(
    resolveBillingAccess(facts({ status: "trialing", grandfatheredAt: null })),
    { access: "full", reason: "status_trialing" }
  );
});

test("#21 United Leather day-30 Stripe cancel for missing payment method: status=canceled -> billing_only", () => {
  assert.deepEqual(
    resolveBillingAccess(facts({ status: "canceled", grandfatheredAt: null })),
    { access: "billing_only", reason: "status_canceled" }
  );
});

// ==========================================================================
// contradictory / edge input never yields arbitrary access
// ==========================================================================
test("edge: billing_required=true + grandfathered + row -> grandfathered (documented precedence, not arbitrary)", () => {
  assert.equal(
    resolveBillingAccess(facts({ grandfatheredAt: "2026-01-01T00:00:00Z", status: "active" })).reason,
    "grandfathered"
  );
});

test("edge: every result is one of exactly two access values", () => {
  const samples = [
    facts({ billingRequired: false }),
    facts({ subscriptionExists: false, status: null }),
    facts({ status: "trialing" }),
    facts({ status: "past_due", pastDueSince: anchorIso }),
    facts({ status: "mystery" }),
  ];
  for (const f of samples) {
    const r = resolveBillingAccess(f);
    assert.ok(r.access === "full" || r.access === "billing_only");
    assert.equal(typeof r.reason, "string");
  }
});
