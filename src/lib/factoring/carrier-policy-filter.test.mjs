// Carrier Factoring Policy panel stays compact: summary, filter tabs, search, scrolling list.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { defaultPolicyFilter, filterCarriers, policyCounts } from "./carrier-policy-filter.ts";

const C = [
  { legal_name: "Silver Line Freight Inc", is_active: true, factoring_mode: "unconfigured" },
  { legal_name: "KALI FR.", is_active: true, factoring_mode: "factored" },
  { legal_name: "cargo sulution", is_active: true, factoring_mode: null },
  { legal_name: "Ortiz Trucking LLC", is_active: true, factoring_mode: "direct" },
  { legal_name: "Old Carrier", is_active: false, factoring_mode: "unconfigured" },
];
const names = (rows) => rows.map((r) => r.legal_name);

test("summary counts active carriers only", () => {
  assert.deepEqual(policyCounts(C), { factored: 1, direct: 1, needsSetup: 2, active: 4 });
});

test("opens on 'Needs setup' when something needs action, else 'All'", () => {
  assert.equal(defaultPolicyFilter(C), "needs_setup");
  assert.equal(defaultPolicyFilter(C.filter((c) => c.factoring_mode === "factored")), "all");
});

test("filters by policy, searches by name (case-insensitive), sorted A-Z", () => {
  assert.deepEqual(names(filterCarriers(C, "needs_setup", "", false)), ["cargo sulution", "Silver Line Freight Inc"]);
  assert.deepEqual(names(filterCarriers(C, "factored", "", false)), ["KALI FR."]);
  assert.deepEqual(names(filterCarriers(C, "direct", "", false)), ["Ortiz Trucking LLC"]);
  assert.equal(filterCarriers(C, "all", "", false).length, 4);
  assert.deepEqual(names(filterCarriers(C, "all", "  silver ", false)), ["Silver Line Freight Inc"]);
});

test("historical carriers: only when shown, and never as 'needs setup'", () => {
  assert.equal(filterCarriers(C, "all", "", true).length, 5);
  assert.deepEqual(names(filterCarriers(C, "needs_setup", "", true)), ["cargo sulution", "Silver Line Freight Inc"]);
});

test("panel renders summary, tabs, search and a fixed-height scrolling list", () => {
  const src = readFileSync(new URL("../../app/(app)/settings/factoring/factoring-settings-client.tsx", import.meta.url), "utf8");
  assert.match(src, /\{counts\.factored\} factored · \{counts\.direct\} direct · \{counts\.needsSetup\} need setup/);
  assert.match(src, /role="tablist" aria-label="Filter carriers by policy"/);
  assert.match(src, /placeholder="Search carriers"/);
  assert.match(src, /max-h-\[296px\] overflow-auto/);
  assert.match(src, /<thead className="sticky top-0 z-10">/);
  assert.match(src, /filterCarriers\(carriers, filter, query, showInactive\)/);
});
