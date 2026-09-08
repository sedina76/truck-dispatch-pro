// PHASE D.2.2 -- static + logic tests for the webhook middleware exposure.
// Run with:  node --test src/lib/
//
// middleware.ts imports next/server + @supabase/ssr, so it cannot be loaded
// under node --test directly. Instead this file reads middleware.ts as
// source, extracts the ACTUAL PUBLIC_PATHS list + the ACTUAL matchesPath
// body, faithfully re-implements the 1-line matcher, and asserts the
// boundary. It also imports the pure route preflight from subscription-
// state.ts to prove the route's own pre-DB signature gate is untouched.
//
// ZERO Stripe calls. ZERO DB. ZERO network.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { preflightWebhookRequest } from "../stripe/subscription-state.ts";

const MW = readFileSync(new URL("./middleware.ts", import.meta.url), "utf8");
const ROUTE = readFileSync(new URL("../../app/api/webhooks/stripe/route.ts", import.meta.url), "utf8");
// Comments in route.ts describe the sequence using the very tokens we grep
// for -- strip full-line `//` comments so source-order assertions look at
// executable code only.
const ROUTE_CODE = ROUTE.replace(/^[ \t]*\/\/.*$/gm, "");

// --- extract the real PUBLIC_PATHS string entries (ignoring // comments) ---
function extractArray(src, name) {
  const start = src.indexOf(`const ${name} = [`);
  assert.ok(start >= 0, `${name} declaration found`);
  const end = src.indexOf("];", start);
  const body = src.slice(src.indexOf("[", start) + 1, end);
  const withoutComments = body.replace(/\/\/[^\n]*/g, "");
  return [...withoutComments.matchAll(/"([^"]+)"/g)].map((m) => m[1]);
}
const PUBLIC_PATHS = extractArray(MW, "PUBLIC_PATHS");

// --- the real matchesPath body, verified unchanged, re-implemented here ---
test("matchesPath semantics are unchanged (exact OR trailing-slash prefix)", () => {
  const norm = MW.replace(/\s+/g, " ");
  assert.ok(
    norm.includes("function matchesPath(pathname: string, path: string): boolean { return pathname === path || pathname.startsWith(`${path}/`); }"),
    "matchesPath is still exactly: pathname === path || pathname.startsWith(`${path}/`)"
  );
});
function matchesPath(pathname, path) {
  return pathname === path || pathname.startsWith(`${path}/`);
}
const isPublic = (pathname) => PUBLIC_PATHS.some((p) => matchesPath(pathname, p));

// ===========================================================================
// 1. unauthenticated request to /api/webhooks/stripe is NOT redirected
// ===========================================================================
test("D.2.2 #1: /api/webhooks/stripe is a public path (no login redirect for an unauthenticated POST)", () => {
  assert.equal(PUBLIC_PATHS.includes("/api/webhooks/stripe"), true, "entry present in PUBLIC_PATHS");
  assert.equal(isPublic("/api/webhooks/stripe"), true);
  // middleware: `if (!user && !isPublicPath) redirect('/login')` -> with
  // isPublicPath true, the redirect is skipped and the request reaches the route.
});

// ===========================================================================
// 2. a neighboring protected route remains protected
// ===========================================================================
test("D.2.2 #2: neighboring protected routes remain protected for an unauthenticated request", () => {
  for (const p of ["/dashboard", "/loads", "/settings/subscription", "/settings/users", "/onboarding"]) {
    assert.equal(isPublic(p), false, `${p} must NOT be public`);
  }
  // (/settings/subscription and /onboarding are subscription-GATE-exempt but
  //  still require authentication -- they are not in PUBLIC_PATHS.)
});

// ===========================================================================
// 3. another non-public API route remains protected
// ===========================================================================
test("D.2.2 #3: other API routes remain protected", () => {
  for (const p of ["/api/loads", "/api/notifications", "/api/webhooks/other", "/api/webhooks", "/api/webhooks/stripe-fake", "/api/webhooks/stripefoo"]) {
    assert.equal(isPublic(p), false, `${p} must NOT be public`);
  }
});

// ===========================================================================
// 4. /api/webhooks/resend behavior unchanged
// ===========================================================================
test("D.2.2 #4: /api/webhooks/resend is still (independently) public", () => {
  assert.equal(PUBLIC_PATHS.includes("/api/webhooks/resend"), true);
  assert.equal(isPublic("/api/webhooks/resend"), true);
  // it is its own entry -- NOT reachable via the new /api/webhooks/stripe entry
  assert.equal(matchesPath("/api/webhooks/resend", "/api/webhooks/stripe"), false);
});

// ===========================================================================
// 5. the new exemption does NOT wildcard all /api/webhooks/*
// ===========================================================================
test("D.2.2 #5: no broad prefix entry was added; only exact /api/webhooks/stripe + its (nonexistent) descendants", () => {
  for (const forbidden of ["/api/webhooks", "/api", "/", "/*", "/api/*", "/api/webhooks/*"]) {
    assert.equal(PUBLIC_PATHS.includes(forbidden), false, `PUBLIC_PATHS must NOT contain "${forbidden}"`);
  }
  // exact path -> public
  assert.equal(isPublic("/api/webhooks/stripe"), true);
  // documented descendant behavior of matchesPath's trailing-slash rule:
  // /api/webhooks/stripe/<child> would be public too -- SAFE because no such
  // route exists (src/app/api/webhooks/stripe/ contains only route.ts).
  assert.equal(isPublic("/api/webhooks/stripe/anything"), true);
  // but a sibling that merely starts with the string is NOT matched
  assert.equal(isPublic("/api/webhooks/stripefoo"), false);
  // and the parent collection is NOT matched
  assert.equal(isPublic("/api/webhooks"), false);
});

test("D.2.2: exactly ONE new PUBLIC_PATHS entry vs the pre-D.2.2 set", () => {
  const expected = new Set([
    "/login", "/signup", "/verify-email", "/forgot-password", "/reset-password",
    "/forgot-email", "/auth/callback", "/driver-portal", "/api/driver-portal",
    "/driver-application", "/api/driver-application", "/carrier-onboarding",
    "/api/webhooks/resend", "/api/webhooks/stripe",
  ]);
  assert.deepEqual(new Set(PUBLIC_PATHS), expected);
});

// ===========================================================================
// 6/7. route still fails BEFORE any DB work on missing secret / signature
// ===========================================================================
test("D.2.2 #6: missing STRIPE_WEBHOOK_SECRET -> 503 preflight failure (before service-role client / claim / DB)", () => {
  assert.deepEqual(preflightWebhookRequest({ secret: undefined, signature: "t=1,v1=x" }), {
    ok: false, status: 503, error: "webhook_not_configured",
  });
  assert.equal(preflightWebhookRequest({ secret: "   ", signature: "x" }).status, 503);
});
test("D.2.2 #7: missing Stripe-Signature -> 400 preflight failure (before DB)", () => {
  assert.deepEqual(preflightWebhookRequest({ secret: "whsec_x", signature: null }), {
    ok: false, status: 400, error: "missing_signature",
  });
  assert.deepEqual(preflightWebhookRequest({ secret: "whsec_x", signature: "t=1,v1=x" }), { ok: true });
});

// ===========================================================================
// 8. invalid signature cannot reach processStripeEvent (source-order proof)
// ===========================================================================
test("D.2.2 #8: route verifies the signature BEFORE constructing the service-role client or calling processStripeEvent", () => {
  const iConstruct = ROUTE_CODE.indexOf("constructEvent(");
  const iServiceClient = ROUTE_CODE.indexOf("createServiceRoleClient(");
  const iProcess = ROUTE_CODE.indexOf("processStripeEvent(");
  assert.ok(iConstruct > 0 && iServiceClient > 0 && iProcess > 0, "all three call sites exist in route.ts code");
  assert.ok(iConstruct < iServiceClient, "constructEvent() precedes createServiceRoleClient()");
  assert.ok(iConstruct < iProcess, "constructEvent() precedes processStripeEvent()");
  // constructEvent is wrapped in try/catch returning 400 before reaching them
  const afterConstruct = ROUTE_CODE.slice(iConstruct, iProcess);
  assert.ok(/catch\s*\(/.test(afterConstruct), "constructEvent() is inside a try/catch before processStripeEvent()");
  assert.ok(/status:\s*400/.test(afterConstruct), "that catch returns HTTP 400 before processStripeEvent()");
  // the route never parses JSON of the body before verification
  assert.equal(ROUTE_CODE.includes("req.json("), false, "route never calls req.json()");
  assert.ok(ROUTE_CODE.includes("req.text()"), "route reads the RAW body via req.text()");
});

// ===========================================================================
// 9. webhook-secret whitespace hardening (route source assertions)
// ===========================================================================
test("D.2/hardening: route normalizes STRIPE_WEBHOOK_SECRET exactly once with (?? \"\").trim()", () => {
  const norm = ROUTE_CODE.replace(/\s+/g, " ");
  assert.ok(
    norm.includes('const webhookSecret = (process.env.STRIPE_WEBHOOK_SECRET ?? "").trim();'),
    "route computes a single trimmed webhookSecret const",
  );
  // exactly ONE read of the env var in executable code
  const reads = [...ROUTE_CODE.matchAll(/process\.env\.STRIPE_WEBHOOK_SECRET/g)];
  assert.equal(reads.length, 1, "STRIPE_WEBHOOK_SECRET is read exactly once");
  // no un-normalized alias like `const webhookSecret: string = secret as string`
  assert.equal(/=\s*secret\s+as\s+string/.test(ROUTE_CODE), false, "no untrimmed secret alias remains");
  assert.equal(ROUTE_CODE.includes("process.env.STRIPE_WEBHOOK_SECRET;"), false, "no raw verbatim assignment");
});

test("D.2/hardening: the SAME webhookSecret const feeds preflight AND constructEvent", () => {
  assert.ok(
    /preflightWebhookRequest\(\{\s*secret:\s*webhookSecret\s*,/.test(ROUTE_CODE.replace(/\s+/g, " ")),
    "preflightWebhookRequest receives the normalized webhookSecret",
  );
  assert.ok(
    /constructEvent\(\s*rawBody\s*,\s*stripeSignature\s*,\s*webhookSecret\s*\)/.test(ROUTE_CODE.replace(/\s+/g, " ")),
    "constructEvent receives the same webhookSecret (3rd arg), plus the raw body + signature header",
  );
});

test("D.2/hardening: normalization happens BEFORE preflight and BEFORE constructEvent; raw body still via req.text()", () => {
  const iNormalize = ROUTE_CODE.indexOf('(process.env.STRIPE_WEBHOOK_SECRET ?? "").trim()');
  const iPreflight = ROUTE_CODE.indexOf("preflightWebhookRequest(");
  const iRawBody = ROUTE_CODE.indexOf("req.text()");
  const iConstruct = ROUTE_CODE.indexOf("constructEvent(");
  assert.ok(iNormalize > 0 && iPreflight > 0 && iRawBody > 0 && iConstruct > 0);
  assert.ok(iNormalize < iPreflight, "normalize before preflight");
  assert.ok(iPreflight < iRawBody, "preflight (secret + signature-header) before the body is read");
  assert.ok(iRawBody < iConstruct, "raw body read before constructEvent");
  // body reaches constructEvent unchanged: same identifier, no parse/stringify between
  const between = ROUTE_CODE.slice(iRawBody, iConstruct);
  assert.equal(/JSON\.(parse|stringify)\(/.test(between), false, "no JSON parse/stringify before verification");
  assert.equal(between.includes("req.json("), false, "no req.json() before verification");
  assert.ok(/const rawBody = await req\.text\(\);/.test(ROUTE_CODE), "rawBody is the awaited req.text() string");
  assert.ok(/constructEvent\(\s*rawBody\s*,/.test(ROUTE_CODE.replace(/\s+/g, " ")), "the SAME rawBody string is passed to constructEvent");
});

test("D.2/hardening: missing-signature behavior unchanged (still preflight 400, before body/DB)", () => {
  // pure-function proof lives in subscription-state.test.mjs; here just prove
  // the route still routes a null header through preflight before req.text().
  const iSigRead = ROUTE_CODE.indexOf('req.headers.get("stripe-signature")');
  const iPreflight = ROUTE_CODE.indexOf("preflightWebhookRequest(");
  const iRawBody = ROUTE_CODE.indexOf("req.text()");
  assert.ok(iSigRead > 0 && iSigRead < iPreflight && iPreflight < iRawBody);
  assert.equal(
    preflightWebhookRequest({ secret: "whsec_x", signature: null }).status,
    400,
    "null Stripe-Signature -> 400 missing_signature",
  );
});

// ===========================================================================
// D.2.10 -- the billing access gate is wired to the authoritative resolver,
// and the old crude deny-list is gone.
// ===========================================================================
const MW_CODE = MW.replace(/^[ \t]*\/\/.*$/gm, "");

test("D.2.10: middleware imports and CALLS resolveBillingAccess (resolver is actually used)", () => {
  assert.match(MW_CODE, /import \{ resolveBillingAccess \} from "@\/lib\/billing\/access-policy"/);
  assert.match(MW_CODE, /const decision = resolveBillingAccess\(\{/);
  // the redirect to the billing page is driven by the resolver's verdict
  assert.match(
    MW_CODE.replace(/\s+/g, " "),
    /if \(decision\.access === "billing_only"\) \{ .*blockedUrl\.pathname = "\/settings\/subscription"; return NextResponse\.redirect\(blockedUrl\); \}/
  );
});

test("D.2.10: the old BLOCKED_SUBSCRIPTION_STATUSES deny-list is removed entirely", () => {
  assert.equal(MW.includes("BLOCKED_SUBSCRIPTION_STATUSES"), false, "no crude status deny-list remains");
  // and no ad-hoc status list is used to decide access
  assert.doesNotMatch(MW_CODE, /\.includes\(subscription\.status\)/);
});

test("D.2.10: middleware passes the minimum facts, keyed on the authenticated profile org id", () => {
  // reads billing_required + the three subscription fields the resolver needs
  assert.match(MW_CODE, /\.from\("organizations"\)\s*\.select\("billing_required"\)/s);
  assert.match(MW_CODE, /\.select\("status, grandfathered_at, past_due_since"\)/);
  // both keyed on profile.organization_id, never a request-supplied id
  assert.match(MW_CODE, /\.eq\("id", profile\.organization_id\)/);
  assert.match(MW_CODE, /\.eq\("organization_id", profile\.organization_id\)/);
  // no service-role client in middleware
  assert.equal(MW.includes("service_role"), false);
  assert.equal(MW.includes("SERVICE_ROLE"), false);
  assert.match(MW_CODE, /process\.env\.NEXT_PUBLIC_SUPABASE_ANON_KEY/);
});

test("D.2.10: a real org/subscription query error is treated as backend-unreachable, not access", () => {
  assert.match(
    MW_CODE.replace(/\s+/g, " "),
    /if \(orgResult\.error \|\| subscriptionResult\.error\) \{ .*pathname = "\/service-unavailable"/
  );
});

test("D.2.10: subscription-gate exemptions are exactly the narrow recovery set (no operational areas)", () => {
  const exempt = extractArray(MW, "SUBSCRIPTION_GATE_EXEMPT_PATHS");
  // string entries declared inline (PUBLIC_PATHS is spread in separately)
  assert.deepEqual(exempt, ["/settings/subscription", "/onboarding", "/admin"]);
  assert.match(MW_CODE, /\.\.\.PUBLIC_PATHS/, "PUBLIC_PATHS still spread into the exempt set");
  // no operational area smuggled in
  for (const op of ["/loads", "/dispatch", "/invoices", "/payments", "/settlements", "/compliance", "/quickbooks", "/carriers", "/drivers"]) {
    assert.equal(exempt.includes(op), false, `${op} must NOT be gate-exempt`);
  }
});

test("D.2.10: page.tsx uses the SAME resolver for its 'access paused' banner (one policy)", () => {
  const PAGE = readFileSync(new URL("../../app/(app)/settings/subscription/page.tsx", import.meta.url), "utf8");
  assert.match(PAGE, /import \{ resolveBillingAccess \} from "@\/lib\/billing\/access-policy"/);
  assert.match(PAGE, /resolveBillingAccess\(\{/);
  assert.match(PAGE, /billingAccess\.access === "billing_only"/);
  assert.equal(PAGE.includes("BLOCKED_STATUSES"), false, "page no longer keeps its own status list");
});

// ===========================================================================
// GET behavior
// ===========================================================================
test("D.2.2: route defines a GET handler that returns 405; POST is the delivery method", () => {
  assert.ok(/export\s+function\s+GET\s*\(/.test(ROUTE), "GET handler present");
  assert.ok(ROUTE.includes("405"), "GET returns 405");
  assert.ok(/export\s+async\s+function\s+POST\s*\(/.test(ROUTE), "POST handler present");
  assert.ok(ROUTE.includes('export const runtime = "nodejs"'), "nodejs runtime (Stripe crypto)");
});
