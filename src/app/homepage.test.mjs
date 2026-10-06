// Public homepage at "/": only that exact path is public, signed-in users
// go to their dashboard, and the page's offer is the real one.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test('only exactly "/" is opened to signed-out visitors', () => {
  const mw = src("../lib/supabase/middleware.ts");
  assert.match(mw, /const isHomepage = request\.nextUrl\.pathname === "\/";/);
  assert.match(mw, /const isPublicPath = isHomepage \|\| PUBLIC_PATHS\.some/);
});

test("signed-in users skip the homepage; the offer matches the real trial", () => {
  const page = src("./page.tsx");
  assert.match(page, /if \(user\) redirect\("\/dashboard"\);/);
  assert.match(page, /30-day free trial · no credit card/);
  assert.match(src("../lib/stripe/checkout.ts"), /const TRIAL_PERIOD_DAYS = 30;/);
  assert.match(page, /href="\/signup"/);
  assert.match(page, /href="\/login"/);
  assert.doesNotMatch(page, /thousands|number one|best in class|unlimited/i, "no claims we can't back up");
});

test("every sign-in / sign-up screen leads back to the homepage", () => {
  const shell = src("../components/auth/auth-shell.tsx");
  assert.match(shell, /<Link href="\/" aria-label="Truck Dispatch Pro home"/);
  assert.match(shell, /<ArrowLeft className="size-4" \/> Home/);
});
