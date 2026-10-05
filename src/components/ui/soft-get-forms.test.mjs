// Filter bars (plain GET forms) navigate inside the app instead of reloading
// the page -- a full reload made the browser leave full screen.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("mounted once in the root layout", () => {
  assert.match(src("../../app/layout.tsx"), /<SoftGetForms \/>/);
});

test("only plain same-site GET submits nobody else handled; files, POST and new tabs untouched", () => {
  const s = src("./soft-get-forms.tsx");
  assert.match(s, /if \(e\.defaultPrevented\) return;/);
  assert.match(s, /window\.addEventListener\("submit", onSubmit\)/); // after React's own (document) listeners
  assert.match(s, /if \(method !== "get"\) return null;/);
  assert.match(s, /if \(url\.origin !== origin\) return null;/);
  assert.match(s, /if \(target && target !== "_self"\) return null;/);
  assert.match(s, /if \(typeof v !== "string"\) return null;/);
  assert.match(s, /router\.push\(href\)/);
});
