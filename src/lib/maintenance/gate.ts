// Full application maintenance gate (Option 4, application half).
//
// Controlled by ONE environment variable: MAINTENANCE_MODE=1 (exactly "1"; anything else -- absent, "0", "true", " 1" -- means OFF and this module does
// nothing). It is evaluated by src/middleware.ts BEFORE any other middleware logic, on every request the middleware matcher covers, for EVERY method
// (Next.js Server Actions are POSTs, but they can also be used for reads, and stale browser tabs may resubmit anything -- so nothing is decided by method).
//
// While ON, every request is answered here with HTTP 503 + Retry-After and a fixed page/JSON body, except:
//   * GET/HEAD /api/health  -> 200 {"status":"maintenance"} (no database, no secrets; exists ONLY while maintenance is on)
//   * /_next/static/*, /favicon.ico -> passed through (the static-asset matcher normally excludes these before the middleware runs at all)
// Login, signup, password reset, authenticated pages, driver portal, onboarding token routes, admin and webhooks are NOT exempt: their handlers are never
// reached, so nothing can write. There are NO redirects (a redirect could loop or hit an auth guard). Responses are never cacheable, so a cached normal page
// cannot survive the transition either way.
//
// This is a broader control than the older DISPATCH_WRITES_DISABLED switch (src/app/(app)/dispatch/actions.ts), which remains in place, unchanged, as a
// NARROWER emergency control for createDispatch/cancelDispatch only. The two are independent and may be used together.
//
// Pure module: no Next.js import, no I/O, no database. The database half of the freeze lives in supabase/proposals/0152/freeze/.

export const MAINTENANCE_MESSAGE =
  "Truck Dispatch Pro is temporarily unavailable while we perform a scheduled system upgrade. No action is required. Please try again shortly.";
export const HEALTH_PATH = "/api/health";
export const DEFAULT_RETRY_AFTER_SECONDS = 900;

type Env = Record<string, string | undefined>;

export type MaintenanceDecision =
  | { action: "pass" }
  | { action: "health"; head: boolean }
  | { action: "block"; kind: "html" | "json"; head: boolean };

/** True only for the exact string "1". The key is read dynamically so the value is evaluated at request time, never inlined at build time. */
export function isMaintenanceMode(env: Env): boolean {
  const key = "MAINTENANCE_MODE";
  return env[key] === "1";
}

/** Retry-After seconds: optional MAINTENANCE_RETRY_AFTER_SECONDS (integer 30..86400), otherwise 900. Never echoes an invalid value. */
export function retryAfterSeconds(env: Env): number {
  const raw = env["MAINTENANCE_RETRY_AFTER_SECONDS"];
  if (typeof raw === "string" && /^[0-9]{1,6}$/.test(raw)) {
    const n = Number(raw);
    if (n >= 30 && n <= 86400) return n;
  }
  return DEFAULT_RETRY_AFTER_SECONDS;
}

function isStaticPass(pathname: string): boolean {
  return pathname.startsWith("/_next/static/") || pathname === "/favicon.ico";
}

export function decideMaintenance(input: { mode: boolean; method: string; pathname: string; accept: string | null }): MaintenanceDecision {
  if (!input.mode) return { action: "pass" };
  const method = input.method.toUpperCase();
  const head = method === "HEAD";
  if (isStaticPass(input.pathname) && (method === "GET" || head)) return { action: "pass" };
  if (input.pathname === HEALTH_PATH && (method === "GET" || head)) return { action: "health", head };
  const accept = (input.accept ?? "").toLowerCase();
  const wantsJson = input.pathname.startsWith("/api/") || (accept.includes("application/json") && !accept.includes("text/html"));
  return { action: "block", kind: wantsJson ? "json" : "html", head };
}

const NO_STORE = "no-store, no-cache, must-revalidate, max-age=0";

function baseHeaders(contentType: string): Record<string, string> {
  return {
    "Content-Type": contentType,
    "Cache-Control": NO_STORE,
    Pragma: "no-cache",
    Expires: "0",
    "CDN-Cache-Control": "no-store",
    "Vercel-CDN-Cache-Control": "no-store",
    "X-Robots-Tag": "noindex, nofollow",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    Vary: "Accept",
  };
}

// Self-contained page: no external font/script/image/stylesheet, inline SVG only. Responsive (viewport + fluid card), light/dark via
// prefers-color-scheme, WCAG-AA contrast in both schemes, semantic landmarks, a single h1, reduced-motion safe (no animation at all).
export const MAINTENANCE_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="color-scheme" content="light dark">
<title>Scheduled maintenance | Truck Dispatch Pro</title>
<style>
:root{--bg:#f4f6f8;--card:#ffffff;--text:#1c2733;--muted:#465566;--brand:#0b5cad;--border:#d5dde5;color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--bg:#0f1720;--card:#17222e;--text:#eef2f6;--muted:#b4c0cc;--brand:#7db8f0;--border:#2b3a49}}
*{box-sizing:border-box}
html,body{margin:0;padding:0}
body{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px 16px;background:var(--bg);color:var(--text);font:16px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
main{width:100%;max-width:34rem;background:var(--card);border:1px solid var(--border);border-radius:14px;padding:32px 24px;text-align:center}
.brand{display:inline-flex;align-items:center;gap:10px;color:var(--brand);font-weight:700;font-size:1.05rem;letter-spacing:.01em}
.brand svg{width:34px;height:34px;flex:none}
h1{margin:20px 0 8px;font-size:1.6rem;line-height:1.25}
p{margin:0 0 12px;color:var(--muted)}
p.lead{color:var(--text);font-size:1.05rem}
.status{display:inline-block;margin-top:8px;padding:4px 12px;border:1px solid var(--border);border-radius:999px;font-size:.85rem;color:var(--muted)}
@media (min-width:600px){main{padding:44px 40px}h1{font-size:1.9rem}}
</style>
</head>
<body>
<main role="main" aria-labelledby="title">
<div class="brand"><svg viewBox="0 0 48 48" role="img" aria-hidden="true" focusable="false"><path fill="currentColor" d="M3 12h27v20H3zM32 18h8l6 8v6H32z"/><circle cx="12" cy="35" r="4.5" fill="var(--card)" stroke="currentColor" stroke-width="3"/><circle cx="37" cy="35" r="4.5" fill="var(--card)" stroke="currentColor" stroke-width="3"/></svg><span>Truck Dispatch Pro</span></div>
<h1 id="title">Scheduled maintenance</h1>
<p class="lead" role="status">${MAINTENANCE_MESSAGE}</p>
<p>Your data is safe. Please reload this page in a few minutes.</p>
<span class="status">Status: maintenance in progress</span>
</main>
</body>
</html>
`;

/** Build the response for a non-pass decision. Only fixed strings and the validated Retry-After number are ever emitted. */
export function maintenanceResponse(decision: Exclude<MaintenanceDecision, { action: "pass" }>, retryAfter: number): Response {
  if (decision.action === "health") {
    const body = JSON.stringify({ status: "maintenance" });
    return new Response(decision.head ? null : body, { status: 200, headers: baseHeaders("application/json; charset=utf-8") });
  }
  const headers = { ...baseHeaders(decision.kind === "json" ? "application/json; charset=utf-8" : "text/html; charset=utf-8"), "Retry-After": String(retryAfter) };
  const body = decision.kind === "json"
    ? JSON.stringify({ error: "maintenance", message: MAINTENANCE_MESSAGE, retry_after_seconds: retryAfter })
    : MAINTENANCE_HTML;
  return new Response(decision.head ? null : body, { status: 503, headers });
}

/** The single entry point used by src/middleware.ts. Returns a Response when the request must be answered here, otherwise null (normal handling). */
export function maintenanceGate(
  request: { method: string; nextUrl: { pathname: string }; headers: { get(name: string): string | null } },
  env: Env
): Response | null {
  const decision = decideMaintenance({
    mode: isMaintenanceMode(env),
    method: request.method,
    pathname: request.nextUrl.pathname,
    accept: request.headers.get("accept"),
  });
  if (decision.action === "pass") return null;
  return maintenanceResponse(decision, retryAfterSeconds(env));
}
