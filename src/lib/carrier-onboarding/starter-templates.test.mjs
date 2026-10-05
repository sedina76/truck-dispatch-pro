// Standard dispatch agreements any subscribing company can add: its name and
// state are filled in, nothing of another company leaks in, and a blank left
// in the text blocks publishing.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { STARTER_TEMPLATES, renderStarter, stateName, unfilledBlanks, clauseKey, STATE_BLANK } from "./starter-templates.ts";

const all = (t) => [t.name, t.description, ...t.clauses.flatMap((c) => [c.title, c.body])].join("\n");

test("three agreements, every clause has a title and body, keys unique", () => {
  assert.deepEqual(STARTER_TEMPLATES.map((t) => t.key), ["dispatch_service_agreement", "limited_authorization", "tracking_communications_consent"]);
  for (const t of STARTER_TEMPLATES) {
    assert.ok(t.clauses.length >= 4);
    const keys = t.clauses.map((c) => clauseKey(c.title));
    assert.equal(new Set(keys).size, keys.length, t.key);
    for (const c of t.clauses) assert.ok(c.title && c.body.length > 40);
  }
});

test("no company is hard-coded: the subscriber's own name and state are filled in", () => {
  for (const t of STARTER_TEMPLATES) assert.doesNotMatch(all(t), /ASAM|Truck Dispatch Pro/i, t.key);
  const r = renderStarter(STARTER_TEMPLATES[0], { name: "Blue Line Dispatch LLC", state: "tx" });
  const text = all(r);
  assert.match(text, /between Blue Line Dispatch LLC \("Dispatcher"\)/);
  assert.match(text, /laws of the State of Texas\./);
  assert.deepEqual(unfilledBlanks([text]), []);
});

test("unknown or missing state leaves a blank that blocks publishing", () => {
  assert.equal(stateName(null), STATE_BLANK);
  assert.equal(stateName("Ontario"), STATE_BLANK);
  assert.equal(stateName("illinois"), "Illinois");
  const r = renderStarter(STARTER_TEMPLATES[0], { name: "X", state: null });
  assert.deepEqual(unfilledBlanks([all(r)]), ["[STATE]"]);
  assert.deepEqual(unfilledBlanks(["Fee is {{fee}} under [PERCENT]"]), ["{{fee}}", "[PERCENT]"]);
  assert.deepEqual(unfilledBlanks(["(a) complete and sign (b) accept"]), []);
});

test("wired: owners/admins see the button; adding skips existing; publish refuses blanks", () => {
  const actions = readFileSync(new URL("../../app/(app)/carriers/onboarding/templates/actions.ts", import.meta.url), "utf8");
  assert.match(actions, /export async function addStarterTemplates\(\)/);
  assert.match(actions, /if \(have\.has\(starter\.key\)\) continue;/);
  assert.match(actions, /const blanks = unfilledBlanks\(/);
  assert.ok(actions.indexOf("const blanks = unfilledBlanks(") < actions.indexOf('rpc("compute_carrier_agreement_content_hash"'));
  const page = readFileSync(new URL("../../app/(app)/carriers/onboarding/templates/page.tsx", import.meta.url), "utf8");
  assert.match(page, /\{canManage && missingStarters\.length > 0 && <AddStarterTemplates missing=\{missingStarters\} \/>\}/);
});
