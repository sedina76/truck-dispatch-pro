// PHASE D.2.14 -- Checkout contract versioning + stale-open-Session
// replacement.
//
// checkout.ts pulls in "server-only", "@/..." aliases and the Stripe SDK,
// so it can't be imported under `node --test`. This reads it as source,
// asserts the new contract, and faithfully re-implements
// evaluateStoredSession()'s verdict logic to run the incident matrix
// executably. ZERO Stripe calls. ZERO DB. ZERO network.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SRC = readFileSync(new URL("./checkout.ts", import.meta.url), "utf8");
const CODE = SRC.replace(/^[ \t]*\/\/.*$/gm, ""); // strip full-line comments

// Extract the actual server-owned contract version string.
const CONTRACT = (SRC.match(/const CHECKOUT_CONTRACT_VERSION = "([^"]+)"/) || [])[1];

// ==========================================================================
// 1. the contract version constant -- semantic, not SHA / not per-request
// ==========================================================================
test("D.2.14 #2/#3: CHECKOUT_CONTRACT_VERSION is one server-owned semantic string", () => {
  assert.ok(CONTRACT && CONTRACT.length > 3, "constant present and non-trivial");
  assert.match(SRC, /const CHECKOUT_CONTRACT_VERSION = "[^"]+";/, "a plain string literal");
  // not a deployment SHA
  assert.doesNotMatch(CONTRACT, /^[0-9a-f]{7,40}$/i, "not a git SHA");
  assert.equal(SRC.includes("VERCEL_GIT_COMMIT_SHA"), false, "not derived from the deploy SHA");
  // not generated per request
  const declLine = SRC.slice(SRC.indexOf("const CHECKOUT_CONTRACT_VERSION"));
  const decl = declLine.slice(0, declLine.indexOf("\n"));
  assert.equal(/Date\.now\(\)|new Date\(|Date\.|toISOString|process\.env/.test(decl), false, "not a timestamp / env value");
  // exactly one assignment
  assert.equal([...SRC.matchAll(/CHECKOUT_CONTRACT_VERSION\s*=/g)].length, 1);
});

// ==========================================================================
// 3/5. stamped into new-Session metadata; existing metadata preserved
// ==========================================================================
test("D.2.14 #4/#5: contract version is added to reconciliationMetadata; durable identity metadata preserved", () => {
  const metaStart = CODE.indexOf("const reconciliationMetadata = {");
  const meta = CODE.slice(metaStart, CODE.indexOf("stripe.checkout.sessions.create(", metaStart));
  assert.match(meta, /checkout_contract_version:\s*CHECKOUT_CONTRACT_VERSION/);
  for (const f of ["organization_id", "plan_id", "plan_tier", "billing_cycle", "price_id", "checkout_attempt_id"]) {
    assert.match(meta, new RegExp(`\\b${f}:`), `existing metadata field ${f} preserved`);
  }
  // reconciliationMetadata is used for BOTH the Session metadata and
  // subscription_data.metadata -> one addition stamps both.
  const create = CODE.slice(CODE.indexOf("stripe.checkout.sessions.create("));
  assert.match(create, /metadata:\s*reconciliationMetadata/); // top-level session.metadata
  assert.match(create, /subscription_data:\s*\{[\s\S]*?metadata:\s*reconciliationMetadata/); // subscription_data.metadata
});

test("D.2.14 #22/#27: the contract version is server-owned -- never from browser input", () => {
  // createSubscriptionCheckout's input is { organizationId, actorUserId, tier, billingCycle }
  assert.match(SRC, /export async function createSubscriptionCheckout\(input: \{\s*organizationId: string;\s*actorUserId: string;\s*tier: string;\s*billingCycle: string;\s*\}/s);
  // the metadata value is the module const, not anything derived from input/args/formData
  assert.doesNotMatch(CODE, /checkout_contract_version:\s*(input|args|body|req|formData|params)\b/);
});

// ==========================================================================
// 4/7. evaluateStoredSession rejects a stale-contract open Session for reuse
// ==========================================================================
test("D.2.14 #6/#7/#8: evaluateStoredSession checks the contract version BEFORE the reuse/in_progress branch", () => {
  const fn = CODE.slice(CODE.indexOf("async function evaluateStoredSession("), CODE.indexOf("async function terminateAttempt("));
  const iContract = fn.indexOf("sessionIsCurrentContract(session)");
  const iReuse = fn.indexOf('kind: "reuse"');
  const iInProgress = fn.indexOf('kind: "in_progress"');
  assert.ok(iContract > 0, "contract check present in evaluateStoredSession");
  assert.ok(iContract < iReuse, "contract check precedes {kind:'reuse'}");
  assert.ok(iContract < iInProgress, "contract check precedes {kind:'in_progress'}");
  // stale -> replace (the existing safe path), fail closed
  assert.match(fn, /if \(!sessionIsCurrentContract\(session\)\) return \{ kind: "replace" \};/);
  // the marker check is an exact-equality test against the module const
  assert.match(SRC, /session\.metadata\?\.checkout_contract_version === CHECKOUT_CONTRACT_VERSION/);
});

// ==========================================================================
// executable re-implementation of the open-branch verdict (kept in lockstep
// with checkout.ts by the source assertion above).
// ==========================================================================
const NOW = 1_800_000_000_000; // fixed "now" in ms
const idOf = (v) => (v == null ? null : typeof v === "string" ? v : v.id);
function verdict(session, { customerId = "cus_UL", intentMatchesFrozen = true } = {}) {
  // resource_missing on retrieve
  if (session === "resource_missing") return { kind: "replace" };
  if (session === "transient_error") return { kind: "ambiguous" };
  if (session.status === "complete") {
    // D.2.14A: a completed non-subscription-mode session is positive dead
    // evidence -> replace. A completed subscription-mode session is only
    // "completed" when its minimum identity is coherent (our Customer + a
    // non-null subscription reference); anything uncertain -> ambiguous
    // (never replace a completed subscription-mode session).
    if (session.mode !== "subscription") return { kind: "replace" };
    const customerOk = idOf(session.customer) === customerId;
    const subscriptionRef = idOf(session.subscription ?? null);
    if (!customerOk || subscriptionRef === null) return { kind: "ambiguous" };
    return { kind: "completed" };
  }
  if (session.status === "expired") return { kind: "replace" };
  if (session.status === "open") {
    if (session.expires_at * 1000 <= NOW) return { kind: "replace" };
    const urlOk = typeof session.url === "string" && session.url.length > 0;
    const customerOk = (typeof session.customer === "string" ? session.customer : session.customer?.id) === customerId;
    if (!urlOk || !customerOk) return { kind: "ambiguous" };
    if ((session.metadata?.checkout_contract_version) !== CONTRACT) return { kind: "replace" };
    return intentMatchesFrozen ? { kind: "reuse", url: session.url } : { kind: "in_progress" };
  }
  return { kind: "ambiguous" };
}
const openBase = { status: "open", expires_at: (NOW + 3600_000) / 1000, url: "https://checkout.stripe.com/x", customer: "cus_UL" };

test("D.2.14 #15/#23: legacy open Session, all intent matches, NO contract marker -> replace (the United Leather incident)", () => {
  const s = { ...openBase, metadata: { organization_id: "org_UL", plan_tier: "essential", billing_cycle: "monthly", price_id: "price_1UBLLMKvkXN4pgdED3H0zeNs" } };
  assert.deepEqual(verdict(s, { intentMatchesFrozen: true }), { kind: "replace" });
});

test("D.2.14 #16: open Session with an OLD contract_version -> replace", () => {
  const s = { ...openBase, metadata: { checkout_contract_version: "2026-08-14d-card-required" } };
  assert.deepEqual(verdict(s, { intentMatchesFrozen: true }), { kind: "replace" });
  // also: empty / null-ish values are stale
  assert.equal(verdict({ ...openBase, metadata: { checkout_contract_version: "" } }).kind, "replace");
  assert.equal(verdict({ ...openBase, metadata: {} }).kind, "replace");
  assert.equal(verdict({ ...openBase, metadata: null }).kind, "replace");
});

test("D.2.14 #17: open Session with the CURRENT contract_version + matching intent -> reuse (no new Session)", () => {
  const s = { ...openBase, metadata: { checkout_contract_version: CONTRACT } };
  assert.deepEqual(verdict(s, { intentMatchesFrozen: true }), { kind: "reuse", url: s.url });
});

test("D.2.14 #18: CURRENT contract but frozen-intent mismatch -> in_progress (contract marker does NOT override intent)", () => {
  const s = { ...openBase, metadata: { checkout_contract_version: CONTRACT } };
  assert.deepEqual(verdict(s, { intentMatchesFrozen: false }), { kind: "in_progress" });
});

test("D.2.14 #18b: wrong customer -> ambiguous, regardless of contract marker", () => {
  const s = { ...openBase, customer: "cus_OTHER", metadata: { checkout_contract_version: CONTRACT } };
  assert.equal(verdict(s).kind, "ambiguous");
});

test("D.2.14 #19: expired Session -> replace (unchanged), even with current contract marker", () => {
  const s = { ...openBase, status: "expired", metadata: { checkout_contract_version: CONTRACT } };
  assert.deepEqual(verdict(s), { kind: "replace" });
  // open-but-past-expires_at also replace
  assert.equal(verdict({ ...openBase, expires_at: (NOW - 1000) / 1000, metadata: { checkout_contract_version: CONTRACT } }).kind, "replace");
});

test("D.2.14 #20 / D.2.14A: completed SUBSCRIPTION-mode Session with coherent identity -> completed (no duplicate-sub replace)", () => {
  const s = { status: "complete", mode: "subscription", customer: "cus_UL", subscription: "sub_123", metadata: { checkout_contract_version: CONTRACT } };
  assert.deepEqual(verdict(s), { kind: "completed" });
  // stale-contract / metadata-less completed SUBSCRIPTION-mode session is
  // STILL 'completed' (never 'replace') as long as identity is coherent --
  // D.2.14A requirement #2.
  assert.deepEqual(verdict({ status: "complete", mode: "subscription", customer: "cus_UL", subscription: "sub_123", metadata: {} }), { kind: "completed" });
});

test("D.2.14: retrieve resource_missing -> replace; transient -> ambiguous (unchanged)", () => {
  assert.deepEqual(verdict("resource_missing"), { kind: "replace" });
  assert.deepEqual(verdict("transient_error"), { kind: "ambiguous" });
});

// ==========================================================================
// D.2.14A -- completed non-subscription Checkout Session trap.
// A completed one-time `payment` (or `setup`) Session stored as the org's
// checkout pointer used to short-circuit to { kind: "completed" } ->
// already_completed -> router.refresh(), trapping the org with no way to
// start a real trial.
// ==========================================================================
test("D.2.14A: source -- the complete branch checks mode + identity BEFORE returning 'completed'", () => {
  const fn = CODE.slice(CODE.indexOf("async function evaluateStoredSession("), CODE.indexOf("async function terminateAttempt("));
  const iComplete = fn.indexOf('session.status === "complete"');
  const iModeGuard = fn.indexOf('session.mode !== "subscription"');
  const iCustomerOk = fn.indexOf("stripeIdOf(session.customer) === customerId");
  const iSubRef = fn.indexOf("session.subscription");
  const iCompletedReturn = fn.indexOf('return { kind: "completed" };');
  assert.ok(iComplete > 0 && iModeGuard > iComplete, "mode guard is inside the complete branch");
  assert.ok(iModeGuard < iCompletedReturn, "mode guard precedes the 'completed' return");
  assert.ok(iCustomerOk > iComplete && iCustomerOk < iCompletedReturn, "customer coherence checked before 'completed'");
  assert.ok(iSubRef > iComplete && iSubRef < iCompletedReturn, "subscription reference checked before 'completed'");
  assert.match(fn, /if \(session\.mode !== "subscription"\) return \{ kind: "replace" \};/);
  assert.match(fn, /if \(!customerOk \|\| subscriptionRef === null\) return \{ kind: "ambiguous" \};/);
});

test("D.2.14A #5.1: completed PAYMENT-mode Session -> replace (the MedFusion / old $30 checkout)", () => {
  const s = { status: "complete", mode: "payment", customer: "cus_UL", subscription: null, metadata: {} };
  assert.deepEqual(verdict(s), { kind: "replace" });
  // even if the customer matches and there is nonsense in metadata
  assert.deepEqual(verdict({ status: "complete", mode: "payment", customer: "cus_UL", metadata: { checkout_contract_version: CONTRACT } }), { kind: "replace" });
});

test("D.2.14A #5.2: completed SETUP-mode Session -> replace", () => {
  assert.deepEqual(verdict({ status: "complete", mode: "setup", customer: "cus_UL", subscription: null, metadata: {} }), { kind: "replace" });
});

test("D.2.14A #5.3: completed subscription-mode + correct customer + subscription ref -> completed", () => {
  assert.deepEqual(
    verdict({ status: "complete", mode: "subscription", customer: "cus_UL", subscription: "sub_abc", metadata: {} }),
    { kind: "completed" }
  );
  // expanded subscription object form also works
  assert.deepEqual(
    verdict({ status: "complete", mode: "subscription", customer: "cus_UL", subscription: { id: "sub_abc" }, metadata: {} }),
    { kind: "completed" }
  );
});

test("D.2.14A #5.4: completed subscription-mode with MISSING subscription -> ambiguous (fail closed, NOT replace)", () => {
  const v = verdict({ status: "complete", mode: "subscription", customer: "cus_UL", subscription: null, metadata: {} });
  assert.deepEqual(v, { kind: "ambiguous" });
  assert.notEqual(v.kind, "replace", "must never replace a completed subscription-mode session");
});

test("D.2.14A #5.5: completed subscription-mode with WRONG customer -> ambiguous (fail closed, NOT replace)", () => {
  const v = verdict({ status: "complete", mode: "subscription", customer: "cus_OTHER", subscription: "sub_abc", metadata: {} });
  assert.deepEqual(v, { kind: "ambiguous" });
  assert.notEqual(v.kind, "replace");
});

test("D.2.14A #5.6/#5.7: a completed non-subscription pointer maps to the replace path -> one fresh Session, no already_completed loop", () => {
  // 8a maps verdict.kind:
  //   "completed" -> { ok:true, kind:"already_completed" }   (=> checkout-cta router.refresh)
  //   "replace"   -> terminateAttempt (CAS on that session id) + continue -> 8c randomUUID -> ONE create()
  const flat = CODE.replace(/\s+/g, " ");
  assert.match(flat, /if \(verdict\.kind === "completed"\) return \{ ok: true, kind: "already_completed" \};/);
  assert.match(flat, /if \(attempt === 0\) \{ await terminateAttempt\(service, cur\.id, cur\.stripe_checkout_session_id\); continue;/);
  assert.equal([...CODE.matchAll(/stripe\.checkout\.sessions\.create\(/g)].length, 1, "still exactly one Session creator");
  // a completed payment-mode session no longer reaches the already_completed
  // path: verdict() proves it now returns 'replace'.
  assert.equal(verdict({ status: "complete", mode: "payment", customer: "cus_UL", metadata: {} }).kind, "replace");
});

test("D.2.14A: contract-version open-Session replacement behavior is unchanged", () => {
  assert.equal(verdict({ ...openBase, metadata: {} }).kind, "replace"); // missing marker
  assert.equal(verdict({ ...openBase, metadata: { checkout_contract_version: CONTRACT } }).kind, "reuse"); // current marker
});

// ==========================================================================
// 8/16/21. stale-contract replacement enters the EXISTING path -> new attempt
// UUID + attempt-derived idempotency key + one creator + CAS concurrency.
// ==========================================================================
test("D.2.14 #16/#21: 'replace' routes through terminateAttempt -> branch 8c (randomUUID) -> one create()", () => {
  const flat = CODE.replace(/\s+/g, " ");
  // 8a: a 'replace' verdict on attempt 0 -> terminateAttempt + continue
  assert.match(flat, /if \(verdict\.kind === "reuse"\) return \{ ok: true, kind: "redirect", url: verdict\.url \};/);
  assert.match(flat, /if \(attempt === 0\) \{ await terminateAttempt\(service, cur\.id, cur\.stripe_checkout_session_id\); continue;/);
  // 8c: brand-new attempt via randomUUID under the triple-null CAS
  assert.match(CODE, /const newAttemptId = randomUUID\(\);/);
  assert.match(CODE.replace(/\s+/g, " "), /\.is\("stripe_checkout_session_id", null\) \.is\("stripe_checkout_attempt_id", null\) \.is\("checkout_pending_since", null\)/);
  // idempotency key = prefix + rowId + attemptId (new attempt => new key)
  assert.match(CODE, /idempotencyKey = `\$\{CHECKOUT_IDEMPOTENCY_PREFIX\}\$\{rowId\}_\$\{attemptId\}`/);
  // still exactly ONE session creator in the whole file
  assert.equal([...CODE.matchAll(/stripe\.checkout\.sessions\.create\(/g)].length, 1);
  // stale-contract replacement does NOT go through the 8b lease-takeover
  // path (which preserves the attempt id) -- 8a 'replace' clears the
  // attempt id via terminateAttempt first.
  assert.match(CODE, /stripe_checkout_attempt_id: null,\s*\n\s*checkout_pending_since: null,/);
});

// ==========================================================================
// 10/24. the fresh-Session contract is unchanged 30-day cardless, all cycles
// ==========================================================================
test("D.2.14 #10/#24/#25/#26: fresh Session create() is 30-day cardless, fail-closed, one payload for all tiers/cycles", () => {
  const create = CODE.slice(CODE.indexOf("stripe.checkout.sessions.create("), CODE.indexOf("{ idempotencyKey }"));
  assert.match(create, /mode:\s*"subscription"/);
  assert.match(create, /payment_method_collection:\s*"if_required"/);
  assert.match(create, /trial_period_days:\s*TRIAL_PERIOD_DAYS/);
  assert.match(SRC, /const TRIAL_PERIOD_DAYS = 30;/);
  assert.match(create.replace(/\s+/g, " "), /trial_settings:\s*\{ end_behavior:\s*\{ missing_payment_method:\s*"cancel" \} \}/);
  assert.match(create, /line_items:\s*\[\{ price: frozenPriceId, quantity: 1 \}\]/);
  // Price is server-resolved per frozen cycle -> same code path for
  // essential/pro x monthly/annual; no per-tier branch in the payload.
  assert.match(CODE, /frozenPriceId = priceForCycle\(frozenPlan, frozenCycle\)/);
  assert.doesNotMatch(create, /"always"/);
  assert.doesNotMatch(create, /trial_period_days:\s*14\b/);
});

// ==========================================================================
// 11. no active obsolete 14-day / card-required policy anywhere in checkout.ts
// ==========================================================================
test("D.2.14 #11: checkout.ts has no active 14-day / payment_method_collection:'always' / 'Start 14-Day Trial'", () => {
  assert.doesNotMatch(CODE, /TRIAL_PERIOD_DAYS\s*=\s*14\b/);
  assert.doesNotMatch(CODE, /payment_method_collection:\s*"always"/);
  assert.doesNotMatch(SRC, /Start 14-Day Trial/);
});

// ==========================================================================
// 12/13. success/cancel + org-resolution untouched
// ==========================================================================
test("D.2.14 #12/#13/#28: success/cancel urls unchanged; contract version is metadata-only, not tenant identity", () => {
  assert.match(SRC, /success_url:\s*`\$\{siteUrl\}\$\{SUCCESS_PATH\}`/);
  assert.match(SRC, /cancel_url:\s*`\$\{siteUrl\}\$\{CANCEL_PATH\}`/);
  // subscription-state.ts (webhook org resolution) never reads the marker
  const STATE = readFileSync(new URL("./subscription-state.ts", import.meta.url), "utf8");
  assert.equal(STATE.includes("checkout_contract_version"), false, "org resolution must not consult the contract marker");
});
