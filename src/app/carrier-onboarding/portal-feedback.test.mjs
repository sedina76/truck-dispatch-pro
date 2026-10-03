// The carrier onboarding portal reports every Save / Continue result: its
// layout mounts the toast area (without it, errors were silently dropped and
// the button seemed to do nothing), and the Company step also shows the
// error under its buttons. The Continue label matches where it goes.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("the carrier portal mounts the toast area around every step", () => {
  const layout = src("./(portal)/layout.tsx");
  assert.match(layout, /import \{ ToastProvider \} from "@\/components\/ui\/toast";/);
  assert.match(layout, /<ToastProvider>[\s\S]*\{children\}[\s\S]*<\/ToastProvider>/);
});

test("the Company step shows save errors under its buttons and continues to Tax Info", () => {
  const form = src("./(portal)/company/company-form.tsx");
  assert.match(form, /setError\(result\.error\)/);
  assert.match(form, /role="alert"/);
  assert.match(form, /router\.push\("\/carrier-onboarding\/w9"\)/);
  assert.match(form, /"Continue to Tax Info"/);
});

test("failed company saves are logged on the server with the reason", () => {
  const actions = src("./actions.ts");
  assert.match(actions, /\[carrier-onboarding\] company save failed:/);
  assert.match(actions, /\[carrier-onboarding\] company save refused: no active onboarding session/);
});
