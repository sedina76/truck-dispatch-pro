// AI rate-confirmation entry: the model's answer is cleaned before it touches
// the form (bad values dropped, never guessed), stops are split the way the
// form expects, the broker is matched to your list, and nothing is saved by
// the AI -- the dispatcher reviews and clicks Create Load.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { normalizeExtraction, parseModelJson, splitStops, matchBroker, RATE_CON_SCHEMA } from "./rate-con.ts";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("cleans dates, times, states, money; drops what it can't trust", () => {
  const x = normalizeExtraction({
    broker_name: "  TQL  ",
    broker_mc_number: "MC-411443",
    rate_total: "$2,450.00",
    equipment_type: "dry_van",
    weight_lbs: "42,000",
    stops: [
      { stop_type: "pickup", city: "West Valley City", state: "ut", date: "10/6/26", time: "8:00 AM", window_end: "14:00", timezone: "America/Denver" },
      { stop_type: "delivery", city: "San Diego", state: "California", date: "2026-10-08", time: "FCFS", timezone: "Mars/Base" },
    ],
  });
  assert.equal(x.broker_name, "TQL");
  assert.equal(x.broker_mc_number, "411443");
  assert.equal(x.rate_total, 2450);
  assert.equal(x.weight_lbs, 42000);
  assert.deepEqual([x.stops[0].state, x.stops[0].date, x.stops[0].time, x.stops[0].window_end, x.stops[0].timezone], ["UT", "2026-10-06", "08:00", "14:00", "America/Denver"]);
  assert.deepEqual([x.stops[1].state, x.stops[1].time, x.stops[1].timezone], ["", "", ""], "full state name, FCFS and unknown zone are left for the dispatcher");
  assert.equal(normalizeExtraction({ linehaul: 2000, accessorials: [{ description: "Lumper", amount: 150 }] }).rate_total, 2150);
  assert.equal(normalizeExtraction({ equipment_type: "spaceship" }).equipment_type, "");
  assert.equal(normalizeExtraction(null).stops.length, 0);
});

test("reads JSON even with fences or stray text", () => {
  assert.deepEqual(parseModelJson('```json\n{"a":1}\n```'), { a: 1 });
  assert.deepEqual(parseModelJson('Here you go: {"a":2} thanks'), { a: 2 });
  assert.throws(() => parseModelJson("no json here"));
});

test("first pickup -> Pickup, last delivery -> Delivery, others -> Additional Stops in order", () => {
  const st = (stop_type, city) => ({ stop_type, city });
  const r = splitStops([st("pickup", "A"), st("pickup", "B"), st("delivery", "C"), st("delivery", "D")]);
  assert.equal(r.pickup.city, "A");
  assert.equal(r.delivery.city, "D");
  assert.deepEqual(r.extra.map((s) => s.city), ["B", "C"]);
});

test("broker matched by MC, then by name (ignoring LLC/Logistics/punctuation); ambiguous -> none", () => {
  const brokers = [
    { id: "tql", company_name: "Total Quality Logistics, LLC", mc_number: "MC-411443" },
    { id: "ch", company_name: "C.H. Robinson", mc_number: null },
    { id: "a1", company_name: "Acme Freight", mc_number: null },
    { id: "a2", company_name: "Acme Freight West", mc_number: null },
    { id: "b1", company_name: "Blue Line Express", mc_number: null },
    { id: "b2", company_name: "Blue Line Express West", mc_number: null },
  ];
  assert.equal(matchBroker(brokers, "Whatever", "411443"), "tql");
  assert.equal(matchBroker(brokers, "Total Quality Logistics", ""), "tql");
  assert.equal(matchBroker(brokers, "CH Robinson", ""), null, "different spelling isn't forced");
  assert.equal(matchBroker(brokers, "C.H. Robinson Worldwide", ""), "ch");
  assert.equal(matchBroker(brokers, "Acme Freight", ""), "a1", "exact name wins");
  assert.equal(matchBroker(brokers, "Blue Line", ""), null, "two candidates -> let the dispatcher pick");
  assert.equal(matchBroker(brokers, "", ""), null);
});

test("schema has no nullable unions and every object is closed", () => {
  const walk = (node) => {
    if (!node || typeof node !== "object") return;
    if (Array.isArray(node.type)) assert.fail("union type");
    if (node.type === "object") {
      assert.equal(node.additionalProperties, false);
      assert.deepEqual([...node.required].sort(), Object.keys(node.properties).sort());
    }
    for (const v of Object.values(node)) walk(v);
  };
  walk(RATE_CON_SCHEMA);
});

test("wiring: staff-only server action, key stays on the server, review before save", () => {
  const action = src("../../app/(app)/loads/ai-actions.ts");
  assert.match(action, /if \(!STAFF\.has\(String\(role \?\? ""\)\)\) return/);
  assert.ok(!/\.insert\(|\.update\(/.test(action), "the AI never writes a load");
  const api = src("./anthropic.ts");
  assert.match(api, /^import "server-only";/);
  assert.match(api, /"x-api-key": key/);
  assert.ok(!/temperature/.test(api), "no sampling params (rejected by current models)");
  const box = src("../../components/loads/rate-con-fill.ts");
  assert.match(box, /el\.setAttribute\("data-ai-filled", opts\.uncertain \? "check" : "1"\)/);
  assert.ok(!/requestSubmit|\.submit\(\)/.test(box), "never submits the form");
  const page = src("../../app/(app)/loads/new/page.tsx");
  assert.match(page, /\{canSeeFinancials && <RateConAutofill \/>\}/);
  assert.match(page, /export const maxDuration = 60;/);
});
