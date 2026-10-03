// The Tax (W-9) step opens with its form on the first visit (no refresh):
// the step before (Employment for drivers, Company for carriers) creates the
// W-9 draft in its server action, the page reads a freshly created draft back
// by id, and a not-yet-readable draft shows "Preparing" + reloads itself
// instead of a blank page. Both portals mount the toast area.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("driver: Employment's Continue pre-creates the W-9 draft; the W-9 page never renders blank", () => {
  const actions = src("./actions.ts");
  assert.match(actions, /await ensureDriverW9Draft\(identity, service\);\s*return \{ ok: true \};/);
  assert.match(actions, /workerTypeRequiresW9\(app\.worker_type as DriverWorkerType \| null\)/);
  const page = src("./(portal)/tax-w9/page.tsx");
  assert.match(page, /w9 = await getMyDriverW9\(created\.id\);/);
  assert.match(page, /if \(!w9\) return <PreparingW9 \/>;/);
  assert.ok(!/if \(!w9\) return null;/.test(page));
  assert.match(src("./(portal)/layout.tsx"), /<ToastProvider>[\s\S]*\{children\}[\s\S]*<\/ToastProvider>/);
});

test("carrier: Company's Continue pre-creates the W-9 draft; the W-9 page never renders blank", () => {
  const actions = src("../carrier-onboarding/actions.ts");
  assert.match(actions, /await ensureCarrierW9Draft\(identity, supabase\);\s*return \{ ok: true \};/);
  const page = src("../carrier-onboarding/(portal)/w9/page.tsx");
  assert.match(page, /w9 = await getMyW9\(created\.id\);/);
  assert.match(page, /if \(!w9\) return <PreparingW9 title="Taxpayer Information \(W-9\)" \/>;/);
});

test("the Preparing screen reloads the step a few times at most", () => {
  const c = src("../../components/onboarding/preparing-w9.tsx");
  assert.match(c, /router\.refresh\(\)/);
  assert.match(c, /if \(tries\.current >= 4\) return window\.clearInterval\(id\);/);
});
