// New driver settlement: everything is checked BEFORE a settlement is made,
// and the reason is shown on the form (not the generic error page). Found
// live: a driver with no pay rate crashed the page and left a voided
// settlement behind on every try.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const actions = src("../../app/(app)/driver-settlements/actions.ts");
const fn = actions.slice(actions.indexOf("export async function createDriverSettlement"), actions.indexOf("export async function addSettlementLoad"));

test("payable loads are read and checked before the settlement row is inserted", () => {
  const read = fn.indexOf('rpc("get_payable_loads"');
  const insert = fn.indexOf('from("driver_settlements")');
  assert.ok(read > 0 && insert > read);
  assert.match(fn, /no pay rate for/);
  assert.match(fn, /no delivered loads in this period/);
  assert.ok(fn.indexOf("unpriced.length > 0") < insert);
});

test("errors come back to the form; only the redirect leaves the try", () => {
  assert.match(fn, /Promise<CreateSettlementState>/);
  assert.doesNotMatch(fn, /throw new Error/);
  assert.match(fn, /\}\s*\n\s*redirect\(`\/driver-settlements\/\$\{settlementId\}`\);/);
  const form = src("./new-settlement-form.tsx");
  assert.match(form, /useActionState<CreateSettlementState, FormData>\(createDriverSettlement/);
  assert.match(form, /role="alert"/);
  assert.match(src("../../app/(app)/driver-settlements/new/page.tsx"), /<NewSettlementForm/);
});
