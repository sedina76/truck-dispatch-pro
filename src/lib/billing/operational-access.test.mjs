// PHASE D.2.11 -- tests for the server-side operational-access paywall.
//
// operational-access.ts imports "server-only", "react", and "@/..." aliases,
// so it can't be imported under `node --test`. This reads it as source and
// asserts the contract, and re-implements its decision wrapper executably on
// top of the REAL resolveBillingAccess (imported directly). It also proves,
// by source assertion, that the operational mutation chokepoints call the
// guard before any write and that billing-recovery / webhook paths do not.
//
// ZERO Stripe calls. ZERO DB. ZERO network.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolveBillingAccess } from "./access-policy.ts";

const HELPER = readFileSync(new URL("./operational-access.ts", import.meta.url), "utf8");
const HELPER_CODE = HELPER.replace(/^[ \t]*\/\/.*$/gm, "");
const read = (rel) => readFileSync(new URL(rel, import.meta.url), "utf8");

// ==========================================================================
// 1. the helper defers to the ONE policy authority -- no duplicated matrix
// ==========================================================================
test("D.2.11 #1/#2: operational-access calls resolveBillingAccess and re-implements NO status matrix", () => {
  assert.match(HELPER_CODE, /import \{ resolveBillingAccess \} from "@\/lib\/billing\/access-policy"/);
  assert.match(HELPER_CODE, /resolveBillingAccess\(\{/);
  // no status matrix / grace arithmetic is duplicated here
  for (const tok of ['"incomplete_expired"', '=== "trialing"', '=== "past_due"', "PAST_DUE_GRACE", "BLOCKED_SUBSCRIPTION_STATUSES", "24 * 60 * 60"]) {
    assert.equal(HELPER_CODE.includes(tok), false, `helper must not contain "${tok}" (policy lives in access-policy.ts)`);
  }
});

// ==========================================================================
// 3/4. trusted org derivation -- from the authenticated profile, never input
// ==========================================================================
test("D.2.11 #3/#4: organization id comes from the authenticated user's profile row, not an argument", () => {
  assert.match(HELPER_CODE, /supabase\.auth\.getUser\(\)/);
  assert.match(HELPER_CODE, /\.from\("profiles"\)\s*\.select\("organization_id"\)\s*\.eq\("id", user\.id\)/s);
  // requireOperationalAccess / checkOperationalAccess take NO parameters
  assert.match(HELPER_CODE, /export async function requireOperationalAccess\(\): Promise/);
  assert.match(HELPER_CODE, /export function checkOperationalAccess\(\): Promise/);
  assert.equal(/requireOperationalAccess\([^)]+\)/.test(HELPER_CODE), false, "no args accepted");
});

// ==========================================================================
// 9. billing-fact query -- billing_required + the three subscription fields
// ==========================================================================
test("D.2.11 #9: reads organizations.billing_required + subscription status/grandfathered_at/past_due_since", () => {
  assert.match(HELPER_CODE, /\.from\("organizations"\)\s*\.select\("billing_required"\)/s);
  assert.match(HELPER_CODE, /\.select\("status, grandfathered_at, past_due_since"\)/);
  assert.equal(HELPER.includes("service_role"), false, "no service-role in the operational gate");
  assert.equal(HELPER.includes("SERVICE_ROLE"), false);
});

// ==========================================================================
// 11/20/30. fail closed
// ==========================================================================
test("D.2.11 #11/#20: a failed billing-state read fails CLOSED (billing_state_unavailable), never grants access", () => {
  assert.match(HELPER_CODE, /if \(orgResult\.error \|\| subscriptionResult\.error\) \{[\s\S]*?billing_state_unavailable/);
  assert.match(HELPER_CODE, /if \(profileError\) \{[\s\S]*?billing_state_unavailable/);
  // the only success RETURN is guarded by decision.access === "full"
  assert.match(HELPER_CODE, /if \(decision\.access !== "full"\) \{[\s\S]*?billing_access_required/);
  const okReturns = [...HELPER_CODE.matchAll(/return \{ ok: true/g)];
  assert.equal(okReturns.length, 1, "exactly one success return");
});

// ==========================================================================
// 12. typed refusal, distinguishable from other failure modes
// ==========================================================================
test("D.2.11 #12: OperationalAccessError carries a stable code distinct from auth/role/validation", () => {
  assert.match(HELPER_CODE, /export class OperationalAccessError extends Error/);
  for (const code of ["billing_access_required", "billing_state_unavailable", "not_authenticated", "no_organization"]) {
    assert.ok(HELPER_CODE.includes(`"${code}"`), `code "${code}" present`);
  }
  // requireOperationalAccess throws it; never returns a success shape on denial
  assert.match(HELPER_CODE, /throw new OperationalAccessError\(result\.code, result\.reason\)/);
});

// ==========================================================================
// 5-19. behavioural: the wrapper's verdict for each billing state, computed
// on the REAL resolver (mirrors the helper's `decision.access !== "full"`).
// ==========================================================================
const NOW = new Date("2026-09-07T12:00:00Z");
const verdict = (over) => {
  const d = resolveBillingAccess({
    billingRequired: true,
    subscriptionExists: true,
    grandfatheredAt: null,
    status: "active",
    pastDueSince: null,
    now: NOW,
    ...over,
  });
  return d.access === "full" ? "allow" : "deny"; // == requireOperationalAccess outcome
};

test("D.2.11 #5 billing_required=false -> allow", () => {
  assert.equal(verdict({ billingRequired: false, subscriptionExists: false, status: null }), "allow");
});
test("D.2.11 #6 grandfathered -> allow", () => {
  assert.equal(verdict({ grandfatheredAt: "2026-09-02T19:32:02Z", status: "canceled" }), "allow");
});
test("D.2.11 #7 active -> allow", () => assert.equal(verdict({ status: "active" }), "allow"));
test("D.2.11 #8 trialing -> allow", () => assert.equal(verdict({ status: "trialing" }), "allow"));
test("D.2.11 #9 past_due inside grace -> allow", () => {
  assert.equal(
    verdict({ status: "past_due", pastDueSince: new Date(NOW.getTime() - 6 * 86400_000).toISOString() }),
    "allow"
  );
});
test("D.2.11 #10 past_due exactly 7d -> deny", () => {
  assert.equal(
    verdict({ status: "past_due", pastDueSince: new Date(NOW.getTime() - 7 * 86400_000).toISOString() }),
    "deny"
  );
});
test("D.2.11 #11 past_due after grace -> deny", () => {
  assert.equal(
    verdict({ status: "past_due", pastDueSince: new Date(NOW.getTime() - 8 * 86400_000).toISOString() }),
    "deny"
  );
});
test("D.2.11 #12 past_due null anchor -> deny", () => {
  assert.equal(verdict({ status: "past_due", pastDueSince: null }), "deny");
});
test("D.2.11 #13 no subscription row -> deny", () => {
  assert.equal(verdict({ subscriptionExists: false, status: null }), "deny");
});
test("D.2.11 #14-18 incomplete/incomplete_expired/unpaid/paused/canceled -> deny", () => {
  for (const s of ["incomplete", "incomplete_expired", "unpaid", "paused", "canceled"]) {
    assert.equal(verdict({ status: s }), "deny", s);
  }
});
test("D.2.11 #19 unknown / null status -> deny", () => {
  assert.equal(verdict({ status: "mystery" }), "deny");
  assert.equal(verdict({ status: null }), "deny");
});

// ==========================================================================
// 21/22/26-33. the chokepoints call the guard BEFORE any write
// ==========================================================================
test("D.2.11 #21/#22: generic records.ts chokepoints gate every managed CRUD before the write", () => {
  const REC = read("../actions/records.ts");
  assert.match(REC, /import \{ requireOperationalAccess \} from "@\/lib\/billing\/operational-access"/);
  for (const fn of ["deleteRecord", "insertRecord", "updateRecord", "updateRecordInPlace"]) {
    const body = REC.slice(REC.indexOf(`export async function ${fn}(`));
    const iGuard = body.indexOf("requireOperationalAccess()");
    const iWrite = body.search(/\.(insert|update|delete)\(/);
    assert.ok(iGuard > 0, `${fn} calls the guard`);
    assert.ok(iGuard < iWrite, `${fn} guards BEFORE the write`);
  }
});

const WRITE_RE = /\.(insert|update|delete|upsert)\(|\.rpc\("(create_|change_|delete_|void_|approve_|record_|restore_|suspend_|lift_)/;
// A write is "gated" if, before it, the action either calls the billing
// guard directly, OR delegates to a generic gated chokepoint
// (insert/update/updateInPlace/deleteRecord), OR calls a file-local
// authorization helper that itself calls the guard (requireFactoringReviewAccess,
// requireOwnerAdminOrg, requireDispatchOpsAccess, requireStopOwnership,
// requireExceptionOwnership -- each verified to contain checkOperationalAccess).
const GUARD_RE = /requireOperationalAccess\(\)|checkOperationalAccess\(\)|\b(?:insertRecord|updateRecord|updateRecordInPlace|deleteRecord)\(|require(?:FactoringReviewAccess|OwnerAdminOrg|DispatchOpsAccess|StopOwnership|ExceptionOwnership)\(/;

// For each async function in the file that performs a write, assert a gate
// appears before that function's first write. Chunks are bounded by the next
// `async function` so trailing helpers are not misattributed.
function assertGatedBeforeWrite(relPath) {
  const src = read(relPath);
  assert.match(src, /billing\/operational-access/, `${relPath} imports the guard`);
  // Only EXPORTED functions are a browser-reachable invocation surface;
  // non-exported helpers (writeLoadFinancials, getOrgFreightItemId, ...) are
  // sub-writes of an already-gated action. Chunk each export up to the next
  // top-level `function ` so its own helpers aren't misattributed forward.
  const rx = /\nexport async function (\w+)\(/g;
  const heads = [...src.matchAll(rx)];
  for (let i = 0; i < heads.length; i++) {
    const name = heads[i][1];
    const start = heads[i].index;
    const end = i + 1 < heads.length ? heads[i + 1].index : src.length;
    const chunk = src.slice(start, end);
    const w = chunk.search(WRITE_RE);
    if (w < 0) continue; // no matched write form in this export
    const g = chunk.search(GUARD_RE);
    assert.ok(g >= 0 && g < w, `${relPath}: ${name}() must be billing-gated before its first write`);
  }
  // At minimum the file must import + reference the guard.
  assert.match(src, GUARD_RE, `${relPath}: references the billing guard`);
}

test("D.2.11 #26 Loads mutations gated", () => {
  assertGatedBeforeWrite("../../app/(app)/loads/actions.ts");
  assertGatedBeforeWrite("../../app/(app)/loads/create-actions.ts");
  assertGatedBeforeWrite("../../app/(app)/loads/pod-actions.ts");
  assertGatedBeforeWrite("../../app/(app)/loads/load-number-actions.ts");
});
test("D.2.11 #27 Dispatch mutations gated", () => {
  assertGatedBeforeWrite("../../app/(app)/dispatch/actions.ts");
  assertGatedBeforeWrite("../../app/(app)/dispatch/board-actions.ts");
  assertGatedBeforeWrite("../../app/(app)/dispatch/route-actions.ts");
  assertGatedBeforeWrite("../../app/(app)/dispatch/exceptions/actions.ts");
});
test("D.2.11 #28 Invoice mutations gated", () => {
  assertGatedBeforeWrite("../../app/(app)/invoices/actions.ts");
  assertGatedBeforeWrite("../../app/(app)/invoices/billing-packet-actions.ts");
  assertGatedBeforeWrite("../../app/(app)/invoices/factoring-actions.ts");
});
test("D.2.11 #29 Payment mutations gated", () => assertGatedBeforeWrite("../../app/(app)/payments/actions.ts"));
test("D.2.11 #30 Settlement mutations gated", () => {
  assertGatedBeforeWrite("../../app/(app)/settlements/actions.ts");
  assertGatedBeforeWrite("../../app/(app)/driver-settlements/actions.ts");
});
test("D.2.11 #31 Driver/Carrier/Broker mutations gated", () => {
  assertGatedBeforeWrite("../../app/(app)/drivers/actions.ts");
  assertGatedBeforeWrite("../../app/(app)/carriers/actions.ts");
  assertGatedBeforeWrite("../../app/(app)/brokers/actions.ts");
  assertGatedBeforeWrite("../../app/(app)/customers/actions.ts");
});
test("D.2.11 #32 Document mutations gated", () => {
  // documents/actions.ts delegates to updateRecord (generic chokepoint);
  // carrier-document-actions is bespoke.
  assertGatedBeforeWrite("../../app/(app)/carriers/carrier-document-actions.ts");
});
test("D.2.11 #33 Fuel/Expense mutations gated", () => {
  assertGatedBeforeWrite("../../app/(app)/fuel/actions.ts");
  assertGatedBeforeWrite("../../app/(app)/expenses/actions.ts");
});
test("D.2.11 #34 Compliance mutations gated", () => {
  // compliance/actions.ts + dot + insurance all delegate to insert/updateRecord.
  assertGatedBeforeWrite("../../app/(app)/carriers/[id]/compliance-actions.ts");
});
test("D.2.11 #35/#36/#37 QuickBooks mapping / invoice export / payment import gated", () => {
  assertGatedBeforeWrite("../../app/(app)/settings/integrations/quickbooks-sync-actions.ts");
  assertGatedBeforeWrite("../../app/(app)/settings/integrations/quickbooks-payment-actions.ts");
});
test("D.2.11: maintenance / collections / statements / advances gated", () => {
  assertGatedBeforeWrite("../../app/(app)/maintenance/actions.ts");
  assertGatedBeforeWrite("../../app/(app)/collections/actions.ts");
  assertGatedBeforeWrite("../../app/(app)/statements/actions.ts");
  assertGatedBeforeWrite("../../app/(app)/advances/actions.ts");
});

// ==========================================================================
// 23/24/25. regression: recovery + webhook + public onboarding NOT gated
// ==========================================================================
test("D.2.11 #23: startSubscriptionCheckout / requestSubscriptionReconciliation are NOT gated", () => {
  const SUB = read("../../app/(app)/settings/subscription/actions.ts");
  assert.equal(SUB.includes("operational-access"), false, "billing recovery must stay reachable for a billing_only tenant");
});
test("D.2.11 #23b: legacy changePlan (grandfathered-only) is NOT gated by the operational paywall", () => {
  const SET = read("../../app/(app)/settings/actions.ts");
  assert.equal(SET.includes("operational-access"), false);
});
test("D.2.11 #24: the signed Stripe webhook + its runtime are NOT gated", () => {
  const ROUTE = read("../../app/api/webhooks/stripe/route.ts");
  const STATE = read("../stripe/subscription-state.ts");
  assert.equal(ROUTE.includes("operational-access"), false);
  assert.equal(STATE.includes("operational-access"), false);
});
test("D.2.11 #25: PUBLIC carrier/driver onboarding actions are NOT gated", () => {
  for (const p of ["../../app/carrier-onboarding/actions.ts", "../../app/driver-onboarding/actions.ts"]) {
    assert.equal(read(p).includes("operational-access"), false, `${p} is a public onboarding surface`);
  }
});

// ==========================================================================
// getCurrentOrgId is left alone (still usable by recovery actions)
// ==========================================================================
test("D.2.11 #4(getCurrentOrgId): the paywall is a SEPARATE helper, not baked into org resolution", () => {
  const REC = read("../actions/records.ts");
  const gco = REC.slice(REC.indexOf("export async function getCurrentOrgId("), REC.indexOf("export async function deleteRecord("));
  assert.equal(gco.includes("requireOperationalAccess"), false, "getCurrentOrgId must not itself gate (recovery actions use it)");
});
