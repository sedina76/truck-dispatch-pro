// Maintenance gate: behaviour, route coverage (derived from the real src/app tree), leakage, and byte-level "off means unchanged" checks.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  maintenanceGate, decideMaintenance, isMaintenanceMode, retryAfterSeconds, maintenanceResponse,
  MAINTENANCE_MESSAGE, MAINTENANCE_HTML, HEALTH_PATH, DEFAULT_RETRY_AFTER_SECONDS,
} from "./gate.ts";

const ON = { MAINTENANCE_MODE: "1" };
const req = (method, pathname, headers = {}) => ({ method, nextUrl: { pathname }, headers: { get: (n) => headers[n.toLowerCase()] ?? null } });
const APP_DIR = fileURLToPath(new URL("../../app", import.meta.url));

// every routable path of the real application, derived from the filesystem (no hand-maintained list)
function routes(dir = APP_DIR, segs = []) {
  const out = [];
  const names = readdirSync(dir);
  if (names.some((n) => /^(page|route)\.(tsx|ts|js|jsx)$/.test(n))) out.push("/" + segs.join("/"));
  for (const n of names) {
    const p = join(dir, n);
    if (!statSync(p).isDirectory()) continue;
    if (n.startsWith("_") || n.startsWith("@")) continue;
    const seg = /^\(.*\)$/.test(n) ? null : /^\[\.\.\..*\]$/.test(n) ? "a/b" : /^\[.*\]$/.test(n) ? "sample-id" : n;
    out.push(...routes(p, seg === null ? segs : [...segs, seg]));
  }
  return out;
}
const ALL_ROUTES = [...new Set(routes())].map((r) => (r === "/" ? "/" : r.replace(/\/$/, "")));

test("route discovery sees the application (dispatch, loads, driver portal, factoring, invoices, admin, webhooks, onboarding)", () => {
  assert.ok(ALL_ROUTES.length > 100, `routes found: ${ALL_ROUTES.length}`);
  for (const must of ["/dispatch/board", "/loads", "/driver-portal", "/api/webhooks/stripe", "/api/webhooks/resend", "/api/driver-portal/location", "/login", "/signup",
                      "/reset-password", "/auth/callback", "/carrier-onboarding", "/settings/factoring"]) {
    assert.ok(ALL_ROUTES.some((r) => r === must || r.startsWith(must + "/")), `route ${must} discovered`);
  }
  assert.ok(ALL_ROUTES.some((r) => r.startsWith("/admin")), "platform-admin routes discovered");
});

test("maintenance OFF: absent / other values pass every request through untouched (returns null)", () => {
  for (const env of [{}, { MAINTENANCE_MODE: "" }, { MAINTENANCE_MODE: "0" }, { MAINTENANCE_MODE: "true" }, { MAINTENANCE_MODE: "yes" }, { MAINTENANCE_MODE: " 1" }, { MAINTENANCE_MODE: "1 " }, { MAINTENANCE_MODE: "01" }, { MAINTENANCE_MODE: undefined }]) {
    assert.equal(isMaintenanceMode(env), false, JSON.stringify(env));
    for (const r of ["/", "/login", "/dispatch/board", "/api/webhooks/stripe", HEALTH_PATH]) {
      for (const m of ["GET", "POST"]) assert.equal(maintenanceGate(req(m, r), env), null, `${m} ${r} ${JSON.stringify(env)}`);
    }
  }
});

test("maintenance ON: EVERY discovered application route is blocked with 503 for EVERY method (nothing is decided by POST alone)", async () => {
  for (const r of ALL_ROUTES) {
    for (const m of ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]) {
      const res = maintenanceGate(req(m, r), ON);
      assert.ok(res, `${m} ${r} must be answered by the gate`);
      assert.equal(res.status, 503, `${m} ${r}`);
      assert.ok(Number(res.headers.get("retry-after")) >= 30, `${m} ${r} Retry-After`);
    }
  }
});

test("server-action POSTs (Next-Action header, any page URL, JSON or HTML accept) and nested routes are blocked", async () => {
  for (const p of ["/dispatch/abc/edit", "/loads/new", "/dispatch/board", "/settings/factoring", "/carriers/onboarding/x/setup-packages/y", "/a/b/c/d/e"]) {
    for (const accept of [null, "text/x-component", "*/*", "text/html", "application/json"]) {
      const res = maintenanceGate(req("POST", p, { "next-action": "abc123", ...(accept ? { accept } : {}) }), ON);
      assert.equal(res.status, 503, `${p} ${accept}`);
    }
  }
});

test("API routes and webhooks get a 503 JSON body; pages get the 503 HTML page; webhooks are not exempt", async () => {
  for (const p of ["/api/webhooks/stripe", "/api/webhooks/resend", "/api/driver-portal/location", "/api/driver-portal/login", "/api/driver-application/submit", "/api/email/send", "/api/integrations/quickbooks/callback", "/api/anything/else"]) {
    const res = maintenanceGate(req("POST", p, { accept: "text/html" }), ON);
    assert.equal(res.status, 503);
    assert.match(res.headers.get("content-type"), /^application\/json/);
    const body = await res.json();
    assert.deepEqual(Object.keys(body).sort(), ["error", "message", "retry_after_seconds"]);
    assert.equal(body.error, "maintenance");
    assert.equal(body.message, MAINTENANCE_MESSAGE);
  }
  const page = maintenanceGate(req("GET", "/dispatch/board", { accept: "text/html,application/xhtml+xml" }), ON);
  assert.equal(page.status, 503);
  assert.match(page.headers.get("content-type"), /^text\/html/);
  assert.equal(await page.text(), MAINTENANCE_HTML);
});

test("login, signup, password reset, auth callback, driver portal, onboarding tokens and admin are NOT exempt", () => {
  for (const p of ["/login", "/signup", "/verify-email", "/forgot-password", "/reset-password", "/forgot-email", "/auth/callback", "/driver-portal", "/driver-portal/trip",
                   "/carrier-onboarding/some-token", "/driver-onboarding/some-token", "/driver-application", "/admin/companies", "/maintenance"]) {
    for (const m of ["GET", "POST"]) assert.equal(maintenanceGate(req(m, p), ON).status, 503, `${m} ${p}`);
  }
});

test("allowlist is narrow: static Next.js assets and favicon pass (GET/HEAD only); /api/health answers 200 {status:'maintenance'} only for GET/HEAD and only EXACTLY that path", async () => {
  for (const p of ["/_next/static/chunks/main.js", "/_next/static/css/app.css", "/favicon.ico"]) {
    assert.equal(maintenanceGate(req("GET", p), ON), null, p);
    assert.equal(maintenanceGate(req("HEAD", p), ON), null, p);
    assert.equal(maintenanceGate(req("POST", p), ON).status, 503, `POST ${p}`);
  }
  assert.equal(maintenanceGate(req("GET", "/_next/staticx/x.js"), ON).status, 503);
  assert.equal(maintenanceGate(req("GET", "/_next/image"), ON).status, 503);
  const h = maintenanceGate(req("GET", HEALTH_PATH), ON);
  assert.equal(h.status, 200);
  assert.deepEqual(await h.json(), { status: "maintenance" });
  assert.equal(maintenanceGate(req("HEAD", HEALTH_PATH), ON).status, 200);
  assert.equal(await maintenanceGate(req("HEAD", HEALTH_PATH), ON).text(), "");
  for (const m of ["POST", "PUT", "DELETE", "PATCH"]) assert.equal(maintenanceGate(req(m, HEALTH_PATH), ON).status, 503, m);
  for (const p of ["/api/health/", "/api/health/x", "/API/health", "/api/healthz", "//api/health", "/api/health%2f", "/x/api/health", "/api/health.json"]) assert.equal(maintenanceGate(req("GET", p), ON).status, 503, p);
});

test("503 responses: status, Retry-After (default 900; configurable 30..86400; invalid ignored), never cacheable, hardened headers, HEAD has no body", async () => {
  const res = maintenanceGate(req("GET", "/dispatch"), ON);
  assert.equal(res.status, 503);
  assert.equal(res.headers.get("retry-after"), String(DEFAULT_RETRY_AFTER_SECONDS));
  assert.match(res.headers.get("cache-control"), /no-store/);
  assert.match(res.headers.get("cache-control"), /max-age=0/);
  assert.equal(res.headers.get("cdn-cache-control"), "no-store");
  assert.equal(res.headers.get("vercel-cdn-cache-control"), "no-store");
  assert.equal(res.headers.get("x-content-type-options"), "nosniff");
  assert.match(res.headers.get("content-security-policy"), /default-src 'none'/);
  assert.match(res.headers.get("x-robots-tag"), /noindex/);
  assert.equal(res.headers.get("location"), null, "never a redirect");
  assert.equal(res.headers.get("set-cookie"), null, "never sets a cookie");
  assert.equal(retryAfterSeconds({ MAINTENANCE_RETRY_AFTER_SECONDS: "1800" }), 1800);
  for (const bad of ["abc", "5", "99999999", "-1", "12.5", "", " 60", "60 "]) assert.equal(retryAfterSeconds({ MAINTENANCE_RETRY_AFTER_SECONDS: bad }), DEFAULT_RETRY_AFTER_SECONDS, bad);
  assert.equal(maintenanceGate(req("GET", "/x"), { ...ON, MAINTENANCE_RETRY_AFTER_SECONDS: "120" }).headers.get("retry-after"), "120");
  const head = maintenanceGate(req("HEAD", "/dispatch"), ON);
  assert.equal(head.status, 503);
  assert.equal(await head.text(), "");
});

test("no redirect loops: the gate never redirects, never reads cookies, and answers /maintenance itself", () => {
  for (const p of ["/", "/login", "/maintenance", "/maintenance/", "/dispatch"]) {
    const res = maintenanceGate(req("GET", p), ON);
    assert.equal(res.status, 503);
    assert.equal(res.headers.get("location"), null);
    assert.equal(res.redirected, false);
  }
});

test("no leakage: no environment value, secret, stack, path or internal detail appears in any body or header", async () => {
  const secretEnv = { ...ON, SUPABASE_SERVICE_ROLE_KEY: "SENTINEL_SERVICE_KEY_123", STRIPE_WEBHOOK_SECRET: "SENTINEL_WHSEC_456", NEXT_PUBLIC_SUPABASE_URL: "https://sentinel-project.supabase.co", RESEND_API_KEY: "SENTINEL_RESEND_789", DATABASE_URL: "postgres://user:SENTINEL_PW@host/db" };
  for (const [m, p, a] of [["GET", "/dispatch", "text/html"], ["POST", "/api/webhooks/stripe", null], ["GET", HEALTH_PATH, null], ["GET", "/login", "application/json"]]) {
    const res = maintenanceGate(req(m, p, a ? { accept: a } : {}), secretEnv);
    const dump = (await res.text()) + JSON.stringify([...res.headers.entries()]);
    assert.doesNotMatch(dump, /SENTINEL|sentinel|supabase\.co|postgres:\/\/|process\.env|node_modules|\/Users\/|\.ts:|Error:|at Object/i, `${m} ${p}`);
  }
  assert.doesNotMatch(MAINTENANCE_HTML, /https?:\/\//, "no absolute URL at all in the page");
});

test("the page: professional copy, accessibility, mobile layout, light/dark, and no external dependency", () => {
  assert.ok(MAINTENANCE_HTML.includes(MAINTENANCE_MESSAGE));
  assert.match(MAINTENANCE_MESSAGE, /temporarily unavailable while we perform a scheduled system upgrade\. No action is required\. Please try again shortly\./);
  assert.match(MAINTENANCE_HTML, /<html lang="en">/);
  assert.match(MAINTENANCE_HTML, /<title>[^<]+<\/title>/);
  assert.match(MAINTENANCE_HTML, /<meta name="viewport" content="width=device-width, initial-scale=1">/);
  assert.equal((MAINTENANCE_HTML.match(/<h1[ >]/g) ?? []).length, 1);
  assert.match(MAINTENANCE_HTML, /<main[^>]*aria-labelledby="title"/);
  assert.match(MAINTENANCE_HTML, /role="status"/);
  assert.match(MAINTENANCE_HTML, /aria-hidden="true"/);
  assert.match(MAINTENANCE_HTML, /prefers-color-scheme:dark/);
  assert.match(MAINTENANCE_HTML, /color-scheme/);
  assert.match(MAINTENANCE_HTML, /@media \(min-width:600px\)/);
  assert.doesNotMatch(MAINTENANCE_HTML, /<script|<link|<img|@import|url\(|src=|href=|<iframe|<form|onerror|onclick/i, "no script, link, image, import, form or external reference");
  assert.match(MAINTENANCE_HTML, /Truck Dispatch Pro/);
});

test("decideMaintenance is pure and mode-first: off => pass for anything", () => {
  assert.deepEqual(decideMaintenance({ mode: false, method: "POST", pathname: "/api/webhooks/stripe", accept: null }), { action: "pass" });
  assert.deepEqual(decideMaintenance({ mode: true, method: "GET", pathname: HEALTH_PATH, accept: null }), { action: "health", head: false });
  assert.equal(maintenanceResponse({ action: "block", kind: "html", head: false }, 60).headers.get("retry-after"), "60");
});

test("middleware covers image-suffixed application URLs and preserves session routing when maintenance is off", async () => {
  const src = readFileSync(new URL("../../middleware.ts", import.meta.url), "utf8");
  const { pathToFileURL } = await import("node:url");
  let calls = 0;
  const pass = { kind: "next" };
  const session = { kind: "session" };
  globalThis.__maintenanceWiringTest = {
    next: () => pass,
    update: () => { calls++; return session; },
  };
  // Exercise the real middleware body with a real gate, stubbing only Next/Supabase.
  const executable = src
    .replace('import { NextResponse, type NextRequest } from "next/server";',
      'const NextResponse = { next: globalThis.__maintenanceWiringTest.next };')
    .replace('import { updateSession } from "@/lib/supabase/middleware";',
      'const updateSession = globalThis.__maintenanceWiringTest.update;')
    .replace('"@/lib/maintenance/gate"', JSON.stringify(pathToFileURL(fileURLToPath(new URL("./gate.ts", import.meta.url))).href))
    .replace('request: NextRequest', 'request');
  const previous = process.env.MAINTENANCE_MODE;
  try {
    const middlewareModule = await import("data:text/javascript;base64," + Buffer.from(executable).toString("base64"));
    // Framework matcher: everything except Next's immutable build files and the favicon.
    const frameworkMatcher = new RegExp("^" + middlewareModule.config.matcher[0] + "$");
    for (const p of ["/", "/login", "/api/example", "/_next/image", "/_next/staticx/token", "/favicon.ico/child",
                     "/carrier-onboarding/token.png", "/driver-onboarding/token.svg", "/logo.png"])
      assert.equal(frameworkMatcher.test(p), true, `matcher covers ${p}`);
    for (const p of ["/_next/static/chunks/main.js", "/_next/static/css/app.css", "/favicon.ico"])
      assert.equal(frameworkMatcher.test(p), false, `matcher skips immutable asset ${p}`);
    process.env.MAINTENANCE_MODE = "1";
    for (const p of ["/carrier-onboarding/token.png", "/driver-onboarding/token.svg", "/api/example.webp",
                     "/_next/staticx/token", "/_next/image", "/favicon.ico/child"]) {
      for (const method of ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]) {
        const response = await middlewareModule.middleware(req(method, p));
        assert.equal(response.status, 503, `${method} ${p}`);
      }
    }
    for (const p of ["/_next/static/chunks/main.js", "/favicon.ico"]) {
      for (const method of ["GET", "HEAD"]) assert.equal(await middlewareModule.middleware(req(method, p)), pass);
      for (const method of ["POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
        assert.equal((await middlewareModule.middleware(req(method, p))).status, 503);
    }
    assert.equal((await middlewareModule.middleware(req("GET", HEALTH_PATH))).status, 200);
    assert.equal(calls, 0, "maintenance blocks before all session/auth work");

    delete process.env.MAINTENANCE_MODE;
    const legacyMatcher = /^\/(?!_next\/static|_next\/image|favicon.ico|.*\.(?:svg|png|jpg|jpeg|gif|webp)$).*/;
    for (const p of [...ALL_ROUTES, "/logo.png", "/carrier-onboarding/token.png", "/driver-onboarding/token.svg",
                     "/_next/static/chunks/main.js", "/_next/staticx/token", "/_next/image", "/favicon.ico/child"]) {
      for (const method of ["GET", "POST"]) {
        assert.equal(await middlewareModule.middleware(req(method, p)), legacyMatcher.test(p) ? session : pass,
          `maintenance off preserves prior session routing: ${method} ${p}`);
      }
    }
  } finally {
    if (previous === undefined) delete process.env.MAINTENANCE_MODE;
    else process.env.MAINTENANCE_MODE = previous;
    delete globalThis.__maintenanceWiringTest;
  }
});

test("the existing DISPATCH_WRITES_DISABLED switch is untouched (still in createDispatch and cancelDispatch)", () => {
  const actions = readFileSync(new URL("../../app/(app)/dispatch/actions.ts", import.meta.url), "utf8");
  assert.equal((actions.match(/process\.env\.DISPATCH_WRITES_DISABLED === "1"/g) ?? []).length, 2);
  assert.match(actions, /DISPATCH_MAINTENANCE_CODE/);
});
