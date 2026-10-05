// Sign up / sign in with Google or Microsoft: buttons only for providers
// switched on, a safe landing page, and failures come back to sign-in.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { enabledProviders, safeNext } from "./oauth-providers.ts";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("providers come from NEXT_PUBLIC_AUTH_PROVIDERS; nothing set = no buttons", () => {
  assert.deepEqual(enabledProviders(undefined), []);
  assert.deepEqual(enabledProviders(""), []);
  assert.deepEqual(enabledProviders("google"), ["google"]);
  assert.deepEqual(enabledProviders(" Google , microsoft, google, github"), ["google", "azure"]);
});

test("after sign-in only same-site pages are allowed", () => {
  assert.equal(safeNext("/dashboard"), "/dashboard");
  assert.equal(safeNext("/reset-password"), "/reset-password");
  assert.equal(safeNext("https://evil.example"), "/dashboard");
  assert.equal(safeNext("//evil.example"), "/dashboard");
  assert.equal(safeNext("/\\evil.example"), "/dashboard");
  assert.equal(safeNext(null), "/dashboard");
});

test("wired: callback handles provider sign-in; sign-in and sign-up pages show the buttons", () => {
  const cb = src("../../app/auth/callback/route.ts");
  assert.match(cb, /const next = safeNext\(searchParams\.get\("next"\)\);/);
  assert.match(cb, /return NextResponse\.redirect\(`\$\{origin\}\/login\?error=oauth`\);/);
  assert.match(src("../../components/auth/oauth-buttons.tsx"), /redirectTo: `\$\{window\.location\.origin\}\/auth\/callback\?flow=oauth&next=\/dashboard`/);
  assert.match(src("../../app/(auth)/signup/page.tsx"), /<OAuthButtons mode="signup" dark \/>/);
  assert.match(src("../../app/(auth)/login/page.tsx"), /<OAuthButtons mode="signin" dark \/>/);
  assert.doesNotMatch(src("../../app/(auth)/signup/page.tsx"), /thousands/i, "no claims we can't back up");
});
