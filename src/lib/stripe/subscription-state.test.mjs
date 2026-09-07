// PHASE D.2 -- focused webhook + reconciliation tests. Run with:
//   node --test src/lib/stripe/
// (Node's built-in test runner + assert; no framework added. Node's native
// TypeScript type-stripping loads the imported .ts module directly.)
//
// ZERO production RPC execution: every Stripe call and every Supabase call
// is a local fake. No network, no DB.

import test from "node:test";
import assert from "node:assert/strict";

import {
  preflightWebhookRequest,
  normalizeStripeStatus,
  unixToIso,
  stripeIdOf,
  extractCanonicalPrice,
  classifyStripeRetrieveError,
  buildInvoiceFact,
  invoiceSubscriptionId,
  computeSecondaryConflict,
  processStripeEvent,
  reconcileOrganizationSubscription,
  SUPPORTED_EVENT_TYPES,
} from "./subscription-state.ts";

const KNOWN_PRICE = "price_1UBLLMKvkXN4pgdED3H0zeNs";

// ---------------------------------------------------------------------------
// fakes
// ---------------------------------------------------------------------------
function makeDb({ rows = {}, rpc } = {}) {
  const calls = [];
  const rpcRouter =
    rpc ??
    ((fn) => {
      if (fn === "claim_stripe_webhook_event") return { data: [{ result: "claimed", claim_token: "tok-1" }], error: null };
      if (fn === "apply_stripe_subscription_state") return { data: "applied", error: null };
      if (fn === "fail_stripe_webhook_event" || fn === "complete_stripe_webhook_event") return { data: true, error: null };
      return { data: null, error: null };
    });
  return {
    calls,
    rpcCalls: () => calls.filter((c) => c.rpc),
    fromCalls: () => calls.filter((c) => c.from),
    rpc(fn, params) {
      calls.push({ rpc: fn, params });
      return Promise.resolve(rpcRouter(fn, params, calls));
    },
    from(table) {
      return {
        select() {
          return {
            eq(column, value) {
              return {
                maybeSingle() {
                  calls.push({ from: table, eq: [column, value] });
                  return Promise.resolve({ data: rows[`${column}:${value}`] ?? null, error: null });
                },
              };
            },
          };
        },
      };
    },
  };
}

function makeStripe({ sub, subError, list, listError } = {}) {
  return {
    subscriptions: {
      retrieveCount: 0,
      retrieve(id) {
        this.retrieveCount++;
        if (subError) return Promise.reject(subError);
        return Promise.resolve(typeof sub === "function" ? sub(id) : sub ?? subFixture({ id }));
      },
      list() {
        if (listError) return Promise.reject(listError);
        return Promise.resolve({ data: list ?? [] });
      },
    },
    invoices: { retrieve: (id) => Promise.resolve({ id }) },
  };
}

function subFixture(over = {}) {
  return {
    id: "sub_123",
    status: "trialing",
    customer: "cus_123",
    cancel_at_period_end: false,
    canceled_at: null,
    ended_at: null,
    trial_end: 1893456000,
    current_period_start: null,
    current_period_end: null,
    items: {
      data: [
        {
          current_period_start: 1893456000,
          current_period_end: 1896134400,
          price: { id: KNOWN_PRICE, recurring: { interval: "month" } },
        },
      ],
    },
    metadata: { organization_id: "org_A" },
    ...over,
  };
}

function evt(type, object, over = {}) {
  return { id: "evt_1", type, api_version: "2026-08-26.dahlia", created: 1893456000, data: { object }, ...over };
}

function lastApplyCall(db) {
  const c = [...db.calls].reverse().find((x) => x.rpc === "apply_stripe_subscription_state");
  return c ? c.params : null;
}
function calledRpcs(db) {
  return db.calls.filter((c) => c.rpc).map((c) => c.rpc);
}

// ===========================================================================
// pure helpers
// ===========================================================================
test("normalizeStripeStatus: 1:1 allow-list, unknown -> null", () => {
  for (const s of ["incomplete", "incomplete_expired", "trialing", "active", "past_due", "unpaid", "canceled", "paused"]) {
    assert.equal(normalizeStripeStatus(s), s);
  }
  assert.equal(normalizeStripeStatus("weird_status"), null);
  assert.equal(normalizeStripeStatus(""), null);
  assert.equal(normalizeStripeStatus(undefined), null);
});

test("unixToIso", () => {
  assert.equal(unixToIso(0), null);
  assert.equal(unixToIso(null), null);
  assert.equal(unixToIso(-5), null);
  assert.equal(unixToIso(1893456000), "2030-01-01T00:00:00.000Z");
});

test("stripeIdOf", () => {
  assert.equal(stripeIdOf("cus_1"), "cus_1");
  assert.equal(stripeIdOf({ id: "cus_2" }), "cus_2");
  assert.equal(stripeIdOf(null), null);
  assert.equal(stripeIdOf(undefined), null);
});

test("extractCanonicalPrice: exactly one recurring item required", () => {
  assert.deepEqual(extractCanonicalPrice(subFixture()), { ok: true, priceId: KNOWN_PRICE, interval: "month" });
  assert.deepEqual(extractCanonicalPrice(subFixture({ items: { data: [] } })), { ok: false, reason: "no_items" });
  assert.deepEqual(
    extractCanonicalPrice(subFixture({ items: { data: [subFixture().items.data[0], subFixture().items.data[0]] } })),
    { ok: false, reason: "multiple_items" }
  );
  assert.deepEqual(
    extractCanonicalPrice(subFixture({ items: { data: [{ price: { recurring: { interval: "month" } } }] } })),
    { ok: false, reason: "no_recurring_price" }
  );
});

test("classifyStripeRetrieveError: ONLY the narrow resource_missing shape", () => {
  assert.equal(classifyStripeRetrieveError({ type: "StripeInvalidRequestError", code: "resource_missing" }), "resource_missing");
  assert.equal(classifyStripeRetrieveError({ type: "StripeInvalidRequestError", statusCode: 404 }), "resource_missing");
  // 404 WITHOUT the invalid-request type -> transient (narrow)
  assert.equal(classifyStripeRetrieveError({ statusCode: 404 }), "transient");
  assert.equal(classifyStripeRetrieveError({ type: "StripeConnectionError" }), "transient");
  assert.equal(classifyStripeRetrieveError({ type: "StripeAuthenticationError" }), "transient");
  assert.equal(classifyStripeRetrieveError({ type: "StripePermissionError" }), "transient");
  assert.equal(classifyStripeRetrieveError({ type: "StripeAPIError", statusCode: 500 }), "transient");
  assert.equal(classifyStripeRetrieveError({ type: "StripeRateLimitError", statusCode: 429 }), "transient");
  assert.equal(classifyStripeRetrieveError(new Error("boom")), "transient");
  assert.equal(classifyStripeRetrieveError(undefined), "transient");
});

test("computeSecondaryConflict: corroboration only, absence is not a conflict", () => {
  assert.equal(computeSecondaryConflict("org_A", {}), null);
  assert.equal(computeSecondaryConflict("org_A", { metaOrgId: "org_A" }), null);
  assert.equal(computeSecondaryConflict("org_A", { metaOrgId: "org_B" }), "metadata_org_id_mismatch");
  assert.equal(computeSecondaryConflict("org_A", { clientReferenceId: "org_B" }), "client_reference_id_mismatch");
  assert.equal(computeSecondaryConflict("org_A", { sessionCustomer: "cus_1", subCustomer: "cus_2" }), "session_customer_mismatch");
});

// ===========================================================================
// R1 / R2 -- route preflight (missing signature / missing secret) = ZERO DB
// ===========================================================================
test("R2: missing webhook secret -> 503, no processing", () => {
  assert.deepEqual(preflightWebhookRequest({ secret: undefined, signature: "t=1,v1=x" }), {
    ok: false,
    status: 503,
    error: "webhook_not_configured",
  });
  assert.deepEqual(preflightWebhookRequest({ secret: "   ", signature: "t=1,v1=x" }).status, 503);
});
test("R1: missing signature header -> 400 (constructEvent-throw -> 400 is handled in route.ts)", () => {
  assert.deepEqual(preflightWebhookRequest({ secret: "whsec_x", signature: null }), {
    ok: false,
    status: 400,
    error: "missing_signature",
  });
  assert.deepEqual(preflightWebhookRequest({ secret: "whsec_x", signature: "t=1,v1=x" }), { ok: true });
});

// ===========================================================================
// R2b -- whitespace-safe webhook-secret normalization (route.ts hardening).
//
// route.ts computes  const webhookSecret = (process.env.STRIPE_WEBHOOK_SECRET
// ?? "").trim();  ONCE and feeds that SAME value to both preflightWebhook-
// Request AND stripe.webhooks.constructEvent. route.ts can't be imported
// under `node --test`, so replicate that one expression here and prove the
// contract it must satisfy.
// ===========================================================================
const normalizeWebhookSecret = (raw) => (raw ?? "").trim();

test("R2b: surrounding whitespace in STRIPE_WEBHOOK_SECRET is stripped before use", () => {
  // leading space, trailing newline, tab+CR -- all common paste artifacts
  for (const raw of [" whsec_abc123", "whsec_abc123\n", "\twhsec_abc123\r\n", "  whsec_abc123  "]) {
    assert.equal(normalizeWebhookSecret(raw), "whsec_abc123", `normalized: ${JSON.stringify(raw)}`);
  }
  // the normalized value is a non-empty string -> preflight passes it through
  assert.deepEqual(
    preflightWebhookRequest({ secret: normalizeWebhookSecret("  whsec_abc123\n"), signature: "t=1,v1=x" }),
    { ok: true },
  );
});

test("R2b: the SAME normalized secret is what constructEvent would receive (no second untrimmed read)", () => {
  const raw = "\n  whsec_padded_secret  \n";
  const normalized = normalizeWebhookSecret(raw);
  assert.equal(normalized, "whsec_padded_secret");
  // route.ts: preflightWebhookRequest({ secret: webhookSecret, ... }) and
  // constructEvent(rawBody, stripeSignature, webhookSecret) -- one const.
  assert.deepEqual(preflightWebhookRequest({ secret: normalized, signature: "t=1,v1=x" }), { ok: true });
  // there is NO trailing/leading whitespace left to corrupt the HMAC key
  assert.equal(normalized, normalized.trim());
  assert.ok(!/^\s|\s$/.test(normalized));
});

test("R2b: blank / whitespace-only / undefined / null secret still -> webhook_not_configured", () => {
  for (const raw of [undefined, null, "", "   ", "\n", "\t\r\n "]) {
    assert.deepEqual(
      preflightWebhookRequest({ secret: normalizeWebhookSecret(raw), signature: "t=1,v1=x" }),
      { ok: false, status: 503, error: "webhook_not_configured" },
      `blank secret: ${JSON.stringify(raw)}`,
    );
  }
});

test("R2b: normalization does NOT touch interior characters of the secret", () => {
  // Stripe secrets have no interior whitespace, but prove .trim() is edge-only.
  assert.equal(normalizeWebhookSecret("  whsec_aa_bb-cc.dd  "), "whsec_aa_bb-cc.dd");
});

// ===========================================================================
// R3 -- unsupported signed event -> no-op success, ZERO DB work
// ===========================================================================
test("R3: unsupported signed event -> 200 ignored, no DB calls at all", async () => {
  const db = makeDb();
  const res = await processStripeEvent(evt("payment_intent.succeeded", { id: "pi_1" }), { stripe: makeStripe(), db });
  assert.equal(res.status, 200);
  assert.equal(res.body.ignored, true);
  assert.equal(db.calls.length, 0);
  // sanity: the event set is exactly the 6 MVP events
  assert.equal(SUPPORTED_EVENT_TYPES.size, 6);
  for (const t of ["charge.succeeded", "customer.created", "invoice.finalized", "invoice.created", "invoice.updated", "entitlements.active_entitlement_summary.updated"]) {
    assert.equal(SUPPORTED_EVENT_TYPES.has(t), false);
  }
});

// ===========================================================================
// R4 / R5 -- duplicate-completed / in-progress claim -> idempotent, no apply
// ===========================================================================
test("R4: already_processed claim -> 200 duplicate, no apply RPC", async () => {
  const db = makeDb({
    rpc: (fn) => (fn === "claim_stripe_webhook_event" ? { data: [{ result: "already_processed", claim_token: null }], error: null } : { data: null, error: null }),
  });
  const res = await processStripeEvent(evt("customer.subscription.updated", subFixture()), { stripe: makeStripe(), db });
  assert.equal(res.status, 200);
  assert.equal(res.body.duplicate, true);
  assert.equal(calledRpcs(db).includes("apply_stripe_subscription_state"), false);
});
test("R5: already_in_progress claim -> 200, no apply RPC", async () => {
  const db = makeDb({
    rpc: (fn) => (fn === "claim_stripe_webhook_event" ? { data: [{ result: "already_in_progress", claim_token: null }], error: null } : { data: null, error: null }),
  });
  const res = await processStripeEvent(evt("customer.subscription.updated", subFixture()), { stripe: makeStripe(), db });
  assert.equal(res.status, 200);
  assert.equal(res.body.in_progress, true);
  assert.equal(calledRpcs(db).includes("apply_stripe_subscription_state"), false);
});

// ===========================================================================
// R6 -- checkout.session.completed: durable Session/Customer match -> canonical
// ===========================================================================
test("R6: checkout.session.completed -> resolves via durable Session mapping, canonical retrieve, apply(mode=apply)", async () => {
  const db = makeDb({ rows: { "stripe_checkout_session_id:cs_1": { id: "osr_1", organization_id: "org_A" } } });
  const stripe = makeStripe({ sub: subFixture({ id: "sub_123", customer: "cus_123" }) });
  const session = { id: "cs_1", mode: "subscription", subscription: "sub_123", customer: "cus_123", client_reference_id: "org_A", metadata: { organization_id: "org_A" } };
  const res = await processStripeEvent(evt("checkout.session.completed", session), { stripe, db });
  assert.equal(stripe.subscriptions.retrieveCount, 1);
  const args = lastApplyCall(db);
  assert.ok(args, "apply RPC was called");
  assert.equal(args.p_mode, "apply");
  assert.equal(args.p_organization_subscription_id, "osr_1");
  assert.equal(args.p_stripe_price_id, KNOWN_PRICE);
  assert.equal(args.p_stripe_checkout_session_id, "cs_1");
  assert.equal(args.p_stripe_subscription_id, "sub_123");
  assert.equal(args.p_secondary_conflict, null);
  assert.equal(args.p_event_at, "2030-01-01T00:00:00.000Z");
  assert.equal(res.status, 200);
  assert.equal(res.body.result, "applied");
});

test("checkout.session.completed with mode != subscription -> terminal no-op, complete_ called, no apply", async () => {
  const db = makeDb();
  const res = await processStripeEvent(evt("checkout.session.completed", { id: "cs_x", mode: "payment" }), { stripe: makeStripe(), db });
  assert.equal(res.status, 200);
  assert.equal(res.body.ignored, true);
  assert.equal(calledRpcs(db).includes("complete_stripe_webhook_event"), true);
  assert.equal(calledRpcs(db).includes("apply_stripe_subscription_state"), false);
});

// ===========================================================================
// R7 -- metadata-only identity -> REJECTED (never adopted)
// ===========================================================================
test("R7: only metadata.organization_id points at an org (no durable row) -> org_unresolved, fail_ called, NO apply", async () => {
  const db = makeDb({ rows: {} }); // nothing maps
  const stripe = makeStripe({ sub: subFixture({ metadata: { organization_id: "org_A" } }) });
  const session = { id: "cs_none", mode: "subscription", subscription: "sub_123", customer: "cus_none", client_reference_id: "org_A", metadata: { organization_id: "org_A" } };
  const res = await processStripeEvent(evt("checkout.session.completed", session), { stripe, db });
  assert.equal(res.status, 500);
  assert.equal(res.body.error, "org_unresolved");
  assert.equal(calledRpcs(db).includes("fail_stripe_webhook_event"), true);
  assert.equal(calledRpcs(db).includes("apply_stripe_subscription_state"), false);
});

// ===========================================================================
// R8 / R9 -- identity conflict -> fail closed
// ===========================================================================
test("R8/R9: durable mappings disagree (sub->rowA, customer->rowB) -> identity_conflict, fail_, NO apply", async () => {
  const db = makeDb({
    rows: {
      "stripe_subscription_id:sub_123": { id: "osr_A", organization_id: "org_A" },
      "stripe_customer_id:cus_123": { id: "osr_B", organization_id: "org_B" },
    },
  });
  const res = await processStripeEvent(evt("customer.subscription.updated", subFixture()), { stripe: makeStripe({ sub: subFixture() }), db });
  assert.equal(res.status, 500);
  assert.equal(res.body.error, "identity_conflict");
  assert.equal(calledRpcs(db).includes("fail_stripe_webhook_event"), true);
  assert.equal(calledRpcs(db).includes("apply_stripe_subscription_state"), false);
});

test("R8/R9: RPC returns reconciliation_required (0127 P6/P7 customer/subscription mismatch) -> 500, ok:false, NOT a clean success", async () => {
  const db = makeDb({
    rows: { "stripe_subscription_id:sub_123": { id: "osr_1", organization_id: "org_A" } },
    rpc: (fn) => {
      if (fn === "claim_stripe_webhook_event") return { data: [{ result: "claimed", claim_token: "tok-1" }], error: null };
      if (fn === "apply_stripe_subscription_state") return { data: "reconciliation_required", error: null };
      return { data: true, error: null };
    },
  });
  const res = await processStripeEvent(evt("customer.subscription.updated", subFixture()), { stripe: makeStripe({ sub: subFixture() }), db });
  assert.equal(res.status, 500);
  assert.equal(res.body.ok, false);
  assert.equal(res.body.reconciliation_required, true);
});

// ===========================================================================
// R10 -- unknown Price -> reconciliation-required / fail-closed
// ===========================================================================
test("R10: multi-item subscription -> price_multiple_items fail-closed, NO apply (RPC shape can't express it)", async () => {
  const db = makeDb({ rows: { "stripe_subscription_id:sub_123": { id: "osr_1", organization_id: "org_A" } } });
  const multi = subFixture({ items: { data: [subFixture().items.data[0], subFixture().items.data[0]] } });
  const res = await processStripeEvent(evt("customer.subscription.updated", multi), { stripe: makeStripe({ sub: multi }), db });
  assert.equal(res.status, 500);
  assert.equal(res.body.error, "price_multiple_items");
  assert.equal(calledRpcs(db).includes("apply_stripe_subscription_state"), false);
});
test("R10: known-shaped single price is passed straight to the RPC (0127 decides unknown vs known)", async () => {
  const db = makeDb({ rows: { "stripe_subscription_id:sub_123": { id: "osr_1", organization_id: "org_A" } } });
  const withUnknownPrice = subFixture({ items: { data: [{ price: { id: "price_totally_unknown", recurring: { interval: "month" } } }] } });
  const res = await processStripeEvent(evt("customer.subscription.updated", withUnknownPrice), { stripe: makeStripe({ sub: withUnknownPrice }), db });
  const args = lastApplyCall(db);
  assert.ok(args);
  assert.equal(args.p_stripe_price_id, "price_totally_unknown"); // handed to 0127, not pre-judged
  assert.equal(res.status, 200); // default fake RPC returns 'applied'; real 0127 would return reconciliation_required
});

// ===========================================================================
// R11 -- unknown subscription status -> fail closed (raw status handed to RPC)
// ===========================================================================
test("R11: unusual status is passed RAW to the RPC (0127 P12 fails it closed into invalid_status)", async () => {
  const db = makeDb({
    rows: { "stripe_subscription_id:sub_123": { id: "osr_1", organization_id: "org_A" } },
    rpc: (fn) => {
      if (fn === "claim_stripe_webhook_event") return { data: [{ result: "claimed", claim_token: "tok-1" }], error: null };
      if (fn === "apply_stripe_subscription_state") return { data: "reconciliation_required", error: null };
      return { data: true, error: null };
    },
  });
  const weird = subFixture({ status: "totally_made_up" });
  const res = await processStripeEvent(evt("customer.subscription.updated", weird), { stripe: makeStripe({ sub: weird }), db });
  const args = lastApplyCall(db);
  assert.equal(args.p_status, "totally_made_up"); // never pre-filtered
  assert.equal(res.status, 500);
  assert.equal(res.body.reconciliation_required, true);
});

// ===========================================================================
// R12 -- subscription.deleted -> authoritative deleted path, NO retrieve
// ===========================================================================
test("R12: customer.subscription.deleted -> deleted-mode apply, canonical retrieve NOT called", async () => {
  const db = makeDb({ rows: { "stripe_subscription_id:sub_123": { id: "osr_1", organization_id: "org_A" } } });
  const stripe = makeStripe();
  const deletedSub = { id: "sub_123", status: "canceled", customer: "cus_123", canceled_at: 1893456000, ended_at: 1893456000, metadata: { organization_id: "org_A" } };
  const res = await processStripeEvent(evt("customer.subscription.deleted", deletedSub), { stripe, db });
  assert.equal(stripe.subscriptions.retrieveCount, 0, "no canonical retrieve for an authoritative deletion");
  const args = lastApplyCall(db);
  assert.equal(args.p_mode, "deleted");
  assert.equal(args.p_stripe_subscription_id, "sub_123");
  assert.equal(args.p_canceled_at, "2030-01-01T00:00:00.000Z");
  assert.equal(args.p_stripe_price_id, null);
  assert.equal(res.status, 200);
});

// ===========================================================================
// D.2.1 AUTHORITATIVE DELETION BOUNDARY -- a canonical-retrieve failure on a
// NON-deleted event NEVER cancels, NEVER calls deleted mode, NEVER writes a
// billing fact. resource_missing is a diagnostic label only.
// ===========================================================================
const RESOURCE_MISSING = { type: "StripeInvalidRequestError", code: "resource_missing" };
const rowsWithSub = { "stripe_subscription_id:sub_123": { id: "osr_1", organization_id: "org_A" }, "stripe_customer_id:cus_123": { id: "osr_1", organization_id: "org_A" }, "stripe_checkout_session_id:cs_1": { id: "osr_1", organization_id: "org_A" } };

test("D.2.1 #1: customer.subscription.deleted -> NO canonical retrieve, deleted mode EXACTLY once", async () => {
  const db = makeDb({ rows: rowsWithSub });
  const stripe = makeStripe();
  const deletedSub = { id: "sub_123", status: "canceled", customer: "cus_123", canceled_at: 1893456000, metadata: { organization_id: "org_A" } };
  await processStripeEvent(evt("customer.subscription.deleted", deletedSub), { stripe, db });
  assert.equal(stripe.subscriptions.retrieveCount, 0);
  const applyCalls = db.calls.filter((c) => c.rpc === "apply_stripe_subscription_state");
  assert.equal(applyCalls.length, 1);
  assert.equal(applyCalls[0].params.p_mode, "deleted");
});

for (const type of ["customer.subscription.created", "customer.subscription.updated"]) {
  test(`D.2.1 #2/#3: ${type} + resource_missing -> canonical_subscription_missing, fail claim, NO apply, NOT canceled`, async () => {
    const db = makeDb({ rows: rowsWithSub });
    const stripe = makeStripe({ subError: RESOURCE_MISSING });
    const res = await processStripeEvent(evt(type, { id: "sub_123", customer: "cus_123", metadata: { organization_id: "org_A" } }), { stripe, db });
    assert.equal(res.status, 500);
    assert.equal(res.body.error, "canonical_subscription_missing");
    assert.equal(calledRpcs(db).includes("apply_stripe_subscription_state"), false, "no apply RPC");
    assert.equal(calledRpcs(db).includes("fail_stripe_webhook_event"), true, "claim failed / retryable");
  });
}

test("D.2.1 #4: checkout.session.completed + resource_missing -> canonical_subscription_missing, fail claim, NO apply, NOT canceled", async () => {
  const db = makeDb({ rows: rowsWithSub });
  const stripe = makeStripe({ subError: RESOURCE_MISSING });
  const session = { id: "cs_1", mode: "subscription", subscription: "sub_123", customer: "cus_123", client_reference_id: "org_A", metadata: { organization_id: "org_A" } };
  const res = await processStripeEvent(evt("checkout.session.completed", session), { stripe, db });
  assert.equal(res.status, 500);
  assert.equal(res.body.error, "canonical_subscription_missing");
  assert.equal(calledRpcs(db).includes("apply_stripe_subscription_state"), false);
  assert.equal(calledRpcs(db).includes("fail_stripe_webhook_event"), true);
});

for (const type of ["invoice.paid", "invoice.payment_failed"]) {
  test(`D.2.1 #5/#6: ${type} + resource_missing -> canonical_subscription_missing, fail claim, NO apply, NO billing fact`, async () => {
    const db = makeDb({ rows: rowsWithSub });
    const stripe = makeStripe({ subError: RESOURCE_MISSING });
    const invoice = { id: "in_1", subscription: "sub_123", customer: "cus_123", status: "open", amount_paid: 5900, amount_due: 5900, currency: "usd" };
    const res = await processStripeEvent(evt(type, invoice), { stripe, db });
    assert.equal(res.status, 500);
    assert.equal(res.body.error, "canonical_subscription_missing");
    assert.equal(calledRpcs(db).includes("apply_stripe_subscription_state"), false, "no apply RPC -> no billing_records write");
    assert.equal(calledRpcs(db).includes("fail_stripe_webhook_event"), true);
  });
}

test("D.2.1 #7: explicit reconciliation + stored sub id resource_missing -> canonical_subscription_missing, NO apply, NOT canceled", async () => {
  const db = makeDb();
  const stripe = makeStripe({ subError: RESOURCE_MISSING });
  const r = await reconcileOrganizationSubscription({ stripe, db }, { row: recRow() });
  assert.equal(r.ok, false);
  assert.equal(r.code, "canonical_subscription_missing");
  assert.equal(calledRpcs(db).includes("apply_stripe_subscription_state"), false);
});

test("D.2.1 #8: transient errors on a non-deleted event -> canonical_retrieve_transient, NOT canceled (regression guard for #14)", async () => {
  for (const subError of [{ type: "StripeConnectionError" }, { type: "StripeAPIError", statusCode: 500 }, { type: "StripeAuthenticationError" }, { type: "StripePermissionError" }, { statusCode: 404 }]) {
    const db = makeDb({ rows: rowsWithSub });
    const res = await processStripeEvent(evt("customer.subscription.updated", { id: "sub_123", customer: "cus_123" }), { stripe: makeStripe({ subError }), db });
    assert.equal(res.status, 500);
    assert.equal(res.body.error, "canonical_retrieve_transient");
    assert.equal(calledRpcs(db).includes("apply_stripe_subscription_state"), false);
  }
});

test("D.2.1 #9: classifyStripeRetrieveError still labels resource_missing (diagnostic only) but no webhook path turns it into deleted mode", async () => {
  assert.equal(classifyStripeRetrieveError(RESOURCE_MISSING), "resource_missing");
  // exhaustive: every NON-deleted supported event, given resource_missing,
  // makes ZERO apply calls (so ZERO deleted-mode calls).
  for (const [type, obj] of [
    ["checkout.session.completed", { id: "cs_1", mode: "subscription", subscription: "sub_123", customer: "cus_123" }],
    ["customer.subscription.created", { id: "sub_123", customer: "cus_123" }],
    ["customer.subscription.updated", { id: "sub_123", customer: "cus_123" }],
    ["invoice.paid", { id: "in_1", subscription: "sub_123", customer: "cus_123", amount_paid: 1 }],
    ["invoice.payment_failed", { id: "in_2", subscription: "sub_123", customer: "cus_123", amount_due: 1 }],
  ]) {
    const db = makeDb({ rows: rowsWithSub });
    await processStripeEvent(evt(type, obj), { stripe: makeStripe({ subError: RESOURCE_MISSING }), db });
    assert.equal(db.calls.filter((c) => c.rpc === "apply_stripe_subscription_state").length, 0, `${type}: no apply -> no deleted mode`);
  }
});

test("D.2.1 #10: static call-site audit -- p_mode:'deleted' is produced from exactly ONE semantic source (customer.subscription.deleted)", async () => {
  const fs = await import("node:fs");
  const src = fs.readFileSync(new URL("./subscription-state.ts", import.meta.url), "utf8");
  // buildDeletedArgs (the only builder that sets p_mode:'deleted') has one call site.
  const callSites = (src.match(/buildDeletedArgs\(/g) ?? []).length;
  const definition = (src.match(/export function buildDeletedArgs/g) ?? []).length;
  assert.equal(definition, 1, "one definition of buildDeletedArgs");
  assert.equal(callSites - definition, 1, "buildDeletedArgs is CALLED from exactly one site");
  // that one call site is inside handleSubscriptionDeleted
  const delHandler = src.slice(src.indexOf("async function handleSubscriptionDeleted"), src.indexOf("// ---- invoice.paid"));
  assert.ok(delHandler.includes("buildDeletedArgs("), "the sole buildDeletedArgs call is in handleSubscriptionDeleted");
  // the removed helper must be gone
  assert.equal(src.includes("deletedFromMissing"), false, "deletedFromMissing helper removed");
  // no literal p_mode: "deleted" anywhere except inside buildDeletedArgs
  const deletedModeLiterals = (src.match(/p_mode:\s*"deleted"/g) ?? []).length;
  assert.equal(deletedModeLiterals, 1, "exactly one p_mode:'deleted' literal (in buildDeletedArgs)");
});

// ===========================================================================
// R14 -- network / 5xx / auth error -> NOT canceled, retryable, lifecycle untouched
// ===========================================================================
for (const [label, subError] of [
  ["connection error", { type: "StripeConnectionError" }],
  ["5xx", { type: "StripeAPIError", statusCode: 500 }],
  ["auth error", { type: "StripeAuthenticationError" }],
  ["permission error", { type: "StripePermissionError" }],
  ["rate limit", { type: "StripeRateLimitError", statusCode: 429 }],
  ["bare 404 (no invalid-request type)", { statusCode: 404 }],
]) {
  test(`R14: .updated + retrieve fails with ${label} -> canonical_retrieve_transient, NO apply, 500`, async () => {
    const db = makeDb({ rows: { "stripe_subscription_id:sub_123": { id: "osr_1", organization_id: "org_A" } } });
    const stripe = makeStripe({ subError });
    const res = await processStripeEvent(evt("customer.subscription.updated", { id: "sub_123", customer: "cus_123" }), { stripe, db });
    assert.equal(res.status, 500);
    assert.equal(res.body.error, "canonical_retrieve_transient");
    assert.equal(calledRpcs(db).includes("apply_stripe_subscription_state"), false);
    assert.equal(calledRpcs(db).includes("fail_stripe_webhook_event"), true);
  });
}

// ===========================================================================
// R15 / R16 / R18 -- invoice fact normalization
// ===========================================================================
test("R15: invoice.paid -> stripe_status 'paid', amount from amount_paid, paid_at set, no delinquency_anchor", () => {
  const fact = buildInvoiceFact("invoice.paid", { id: "in_1", status: "paid", amount_paid: 5900, amount_due: 0, currency: "usd", invoice_pdf: "https://x/pdf", period_start: 1893456000, period_end: 1896134400, status_transitions: { paid_at: 1893456005 } }, 1893456000);
  assert.equal(fact.stripe_status, "paid");
  assert.equal(fact.amount_cents, 5900);
  assert.equal(fact.currency, "usd");
  assert.equal(fact.invoice_pdf_url, "https://x/pdf");
  assert.equal(fact.paid_at, "2030-01-01T00:00:05.000Z");
  assert.equal(fact.delinquency_anchor, null);
});
test("R16: invoice.payment_failed -> stripe_status 'open' (NEVER 'payment_failed'), amount from amount_due, delinquency_anchor = finalized_at", () => {
  const fact = buildInvoiceFact("invoice.payment_failed", { id: "in_2", status: "open", amount_paid: 0, amount_due: 5900, currency: "usd", period_start: 1893456000, period_end: 1896134400, created: 1893450000, status_transitions: { finalized_at: 1893452000 } }, 1893456000);
  assert.equal(fact.stripe_status, "open");
  assert.equal(fact.amount_cents, 5900);
  assert.equal(fact.paid_at, null);
  assert.equal(fact.delinquency_anchor, unixToIso(1893452000));
});
test("R18: buildInvoiceFact can ONLY emit 'paid' or 'open' -- never a raw Stripe status like 'draft'", () => {
  for (const raw of ["draft", "uncollectible", "void", "weird"]) {
    assert.equal(buildInvoiceFact("invoice.paid", { id: "x", status: raw, amount_paid: 1 }, 0).stripe_status, "paid");
    assert.equal(buildInvoiceFact("invoice.payment_failed", { id: "x", status: raw, amount_due: 1 }, 0).stripe_status, "open");
  }
});
test("invoiceSubscriptionId: legacy top-level and new parent.subscription_details shapes", () => {
  assert.equal(invoiceSubscriptionId({ subscription: "sub_9" }), "sub_9");
  assert.equal(invoiceSubscriptionId({ subscription: { id: "sub_10" } }), "sub_10");
  assert.equal(invoiceSubscriptionId({ parent: { subscription_details: { subscription: "sub_11" } } }), "sub_11");
  assert.equal(invoiceSubscriptionId({ id: "in_only" }), null);
});

test("R15 (flow): invoice.paid event -> apply(mode=apply) with p_invoice.stripe_status 'paid' and p_invoice + p_event_at present", async () => {
  const db = makeDb({ rows: { "stripe_subscription_id:sub_123": { id: "osr_1", organization_id: "org_A" } } });
  const stripe = makeStripe({ sub: subFixture({ status: "active" }) });
  const invoice = { id: "in_1", subscription: "sub_123", customer: "cus_123", status: "paid", amount_paid: 5900, currency: "usd", period_start: 1893456000, period_end: 1896134400, status_transitions: { paid_at: 1893456005 } };
  const res = await processStripeEvent(evt("invoice.paid", invoice), { stripe, db });
  const args = lastApplyCall(db);
  assert.equal(args.p_mode, "apply");
  assert.ok(args.p_invoice, "p_invoice present");
  assert.equal(args.p_invoice.stripe_status, "paid");
  assert.equal(args.p_event_at, "2030-01-01T00:00:00.000Z");
  assert.equal(res.status, 200);
});

test("one-off invoice (no subscription) -> terminal no-op, complete_ called, no apply", async () => {
  const db = makeDb();
  const res = await processStripeEvent(evt("invoice.paid", { id: "in_oneoff", amount_paid: 100 }), { stripe: makeStripe(), db });
  assert.equal(res.status, 200);
  assert.equal(res.body.ignored, true);
  assert.equal(calledRpcs(db).includes("complete_stripe_webhook_event"), true);
  assert.equal(calledRpcs(db).includes("apply_stripe_subscription_state"), false);
});

// ===========================================================================
// R17 -- stale lifecycle + fresh valid invoice -> invoice STILL passed to RPC
// ===========================================================================
test("R17: RPC returns stale_skipped_billing_recorded -> 200 success (invoice fact NOT suppressed), p_invoice was sent", async () => {
  const db = makeDb({
    rows: { "stripe_subscription_id:sub_123": { id: "osr_1", organization_id: "org_A" } },
    rpc: (fn) => {
      if (fn === "claim_stripe_webhook_event") return { data: [{ result: "claimed", claim_token: "tok-1" }], error: null };
      if (fn === "apply_stripe_subscription_state") return { data: "stale_skipped_billing_recorded", error: null };
      return { data: true, error: null };
    },
  });
  const stripe = makeStripe({ sub: subFixture({ status: "past_due" }) });
  const invoice = { id: "in_late", subscription: "sub_123", customer: "cus_123", status: "open", amount_due: 5900, currency: "usd", created: 1893450000, status_transitions: { finalized_at: 1893452000 } };
  const res = await processStripeEvent(evt("invoice.payment_failed", invoice, { created: 100 }), { stripe, db });
  const args = lastApplyCall(db);
  assert.ok(args.p_invoice, "invoice fact still handed to the RPC even though lifecycle is stale");
  assert.equal(args.p_invoice.stripe_status, "open");
  assert.equal(args.p_event_at, "1970-01-01T00:01:40.000Z");
  assert.equal(res.status, 200);
  assert.equal(res.body.result, "stale_skipped_billing_recorded");
});

// ===========================================================================
// R19 / R20 -- reconciliation reuses the SAME normalizer, passes NULL event/token
// ===========================================================================
function recRow(over = {}) {
  return {
    id: "osr_1",
    organization_id: "org_A",
    grandfathered_at: null,
    stripe_customer_id: "cus_123",
    stripe_subscription_id: "sub_123",
    stripe_price_id: KNOWN_PRICE,
    billing_required: true,
    ...over,
  };
}

test("R19/R20: reconcile with a stored subscription id -> apply(mode=reconcile), SAME price extraction, event/token NULL", async () => {
  const db = makeDb();
  const stripe = makeStripe({ sub: subFixture({ status: "active" }) });
  const r = await reconcileOrganizationSubscription({ stripe, db }, { row: recRow() });
  assert.equal(r.ok, true);
  assert.equal(r.code, "reconciled");
  const args = lastApplyCall(db);
  assert.equal(args.p_mode, "reconcile");
  assert.equal(args.p_stripe_event_id, null);
  assert.equal(args.p_claim_token, null);
  assert.equal(args.p_stripe_price_id, KNOWN_PRICE);
  assert.equal(args.p_organization_subscription_id, "osr_1");
});

test("R20: reconcile refuses grandfathered / billing_required=false / no mapping -- NO rpc call", async () => {
  for (const [row, code] of [
    [recRow({ grandfathered_at: "2026-01-01T00:00:00Z" }), "grandfathered"],
    [recRow({ billing_required: false }), "billing_not_required"],
    [recRow({ stripe_customer_id: null, stripe_subscription_id: null }), "no_mapping"],
  ]) {
    const db = makeDb();
    const r = await reconcileOrganizationSubscription({ stripe: makeStripe(), db }, { row });
    assert.equal(r.ok, false);
    assert.equal(r.code, code);
    assert.equal(db.calls.length, 0);
  }
});

test("R20: reconcile with only a customer mapping + zero Stripe subscriptions -> no_subscription, no apply, no Stripe writes", async () => {
  const db = makeDb();
  const stripe = makeStripe({ list: [] });
  const r = await reconcileOrganizationSubscription({ stripe, db }, { row: recRow({ stripe_subscription_id: null }) });
  assert.equal(r.ok, true);
  assert.equal(r.code, "no_subscription");
  assert.equal(calledRpcs(db).includes("apply_stripe_subscription_state"), false);
});

test("R20: reconcile with >1 Stripe subscription for the customer -> multiple_subscriptions, no apply", async () => {
  const db = makeDb();
  const stripe = makeStripe({ list: [subFixture({ id: "sub_a" }), subFixture({ id: "sub_b" })] });
  const r = await reconcileOrganizationSubscription({ stripe, db }, { row: recRow({ stripe_subscription_id: null }) });
  assert.equal(r.ok, false);
  assert.equal(r.code, "multiple_subscriptions");
});

test("R20 (D.2.1): reconcile + stored subscription id resource_missing -> canonical_subscription_missing, NO apply, NOT canceled", async () => {
  const db = makeDb();
  const stripe = makeStripe({ subError: { type: "StripeInvalidRequestError", code: "resource_missing" } });
  const r = await reconcileOrganizationSubscription({ stripe, db }, { row: recRow() });
  assert.equal(r.ok, false);
  assert.equal(r.code, "canonical_subscription_missing");
  assert.equal(lastApplyCall(db), null, "no apply_stripe_subscription_state call -- investigation condition, not auto-cancel");
});

test("R20: reconcile + transient Stripe error -> lifecycle untouched, no apply", async () => {
  const db = makeDb();
  const stripe = makeStripe({ subError: { type: "StripeConnectionError" } });
  const r = await reconcileOrganizationSubscription({ stripe, db }, { row: recRow() });
  assert.equal(r.ok, false);
  assert.equal(r.code, "canonical_retrieve_transient");
  assert.equal(calledRpcs(db).includes("apply_stripe_subscription_state"), false);
});

test("R20: reconcile + RPC returns reconciliation_required -> NOT presented as a clean success", async () => {
  const db = makeDb({
    rpc: (fn) => (fn === "apply_stripe_subscription_state" ? { data: "reconciliation_required", error: null } : { data: null, error: null }),
  });
  const r = await reconcileOrganizationSubscription({ stripe: makeStripe({ sub: subFixture() }), db }, { row: recRow() });
  assert.equal(r.ok, false);
  assert.equal(r.code, "reconciliation_required");
});

// ===========================================================================
// misc guardrails
// ===========================================================================
test("apply RPC exception (tx rolled back) -> 500 rpc_exception, no crash", async () => {
  const db = makeDb({
    rows: { "stripe_subscription_id:sub_123": { id: "osr_1", organization_id: "org_A" } },
    rpc: (fn) => {
      if (fn === "claim_stripe_webhook_event") return { data: [{ result: "claimed", claim_token: "tok-1" }], error: null };
      if (fn === "apply_stripe_subscription_state") return { data: null, error: { code: "22023", message: "bad" } };
      return { data: true, error: null };
    },
  });
  const res = await processStripeEvent(evt("customer.subscription.updated", subFixture()), { stripe: makeStripe({ sub: subFixture() }), db });
  assert.equal(res.status, 500);
  assert.equal(res.body.error, "rpc_exception");
});

test("claim RPC error -> 500 claim_failed, nothing else attempted", async () => {
  const db = makeDb({ rpc: (fn) => (fn === "claim_stripe_webhook_event" ? { data: null, error: { code: "XX", message: "x" } } : { data: null, error: null }) });
  const res = await processStripeEvent(evt("customer.subscription.updated", subFixture()), { stripe: makeStripe(), db });
  assert.equal(res.status, 500);
  assert.equal(res.body.error, "claim_failed");
  assert.equal(calledRpcs(db).includes("apply_stripe_subscription_state"), false);
});

test("applied_billing_recorded / applied_billing_conflict mapping", async () => {
  for (const [ret, expectStatus, extra] of [
    ["applied_billing_recorded", 200, {}],
    ["applied_billing_conflict", 200, { reconciliation_flagged: true }],
    ["not_owner", 200, { not_owner: true }],
  ]) {
    const db = makeDb({
      rows: { "stripe_subscription_id:sub_123": { id: "osr_1", organization_id: "org_A" } },
      rpc: (fn) => {
        if (fn === "claim_stripe_webhook_event") return { data: [{ result: "claimed", claim_token: "tok-1" }], error: null };
        if (fn === "apply_stripe_subscription_state") return { data: ret, error: null };
        return { data: true, error: null };
      },
    });
    const res = await processStripeEvent(evt("customer.subscription.updated", subFixture()), { stripe: makeStripe({ sub: subFixture() }), db });
    assert.equal(res.status, expectStatus, ret);
    for (const [k, v] of Object.entries(extra)) assert.equal(res.body[k], v, `${ret}.${k}`);
  }
});
