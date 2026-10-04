// Safety incidents: the form is checked in plain language, the history
// summary counts honestly, photos are stored as photos, and the pages are
// reachable from the menus and from every driver and truck page.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { incidentValues, summarizeHistory, incidentFileType, incidentTypeLabel, INCIDENT_TYPES } from "./incidents.ts";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const form = (o) => ({ get: (k) => (k in o ? o[k] : null) });
const ID = "17000000-0000-0000-0000-0000000000a1";

test("the four kinds match the database check", () => {
  assert.deepEqual([...INCIDENT_TYPES], ["accident", "citation", "cargo_claim", "inspection_violation"]);
  const sql = src("../../../supabase/migrations/0170_safety_incidents.sql");
  assert.match(sql, /incident_type in \('accident', 'citation', 'cargo_claim', 'inspection_violation'\)/);
  assert.equal(incidentTypeLabel("cargo_claim"), "Cargo claim");
  assert.equal(incidentTypeLabel("weird"), "Incident");
});

test("form values: trimmed text, optional links, money parsed", () => {
  const v = incidentValues(
    form({ incident_type: "accident", occurred_on: "2026-10-01", location: "  I-80 MM 120 ", driver_id: ID, truck_id: "", load_id: "not-an-id", cost: "$1,250.505", description: "" }),
    "2026-10-04"
  );
  assert.deepEqual(v, { incident_type: "accident", occurred_on: "2026-10-01", location: "I-80 MM 120", driver_id: ID, truck_id: null, load_id: null, description: null, cost: 1250.51 });
  assert.equal(incidentValues(form({ incident_type: "citation", occurred_on: "2026-10-04" }), "2026-10-04").cost, 0);
});

test("form values: bad input gets a plain message", () => {
  assert.throws(() => incidentValues(form({ incident_type: "speeding", occurred_on: "2026-10-01" }), "2026-10-04"), /what kind of incident/);
  assert.throws(() => incidentValues(form({ incident_type: "citation", occurred_on: "" }), "2026-10-04"), /date it happened/);
  assert.throws(() => incidentValues(form({ incident_type: "citation", occurred_on: "2026-10-05" }), "2026-10-04"), /future/);
  assert.throws(() => incidentValues(form({ incident_type: "citation", occurred_on: "2026-10-01", cost: "-5" }), "2026-10-04"), /zero or more/);
  assert.throws(() => incidentValues(form({ incident_type: "citation", occurred_on: "2026-10-01", cost: "abc" }), "2026-10-04"), /zero or more/);
});

test("history summary: totals, last 12 months, open, by type, cost", () => {
  const rows = [
    { incident_type: "accident", occurred_on: "2026-09-01", cost: "1000.10", status: "open" },
    { incident_type: "citation", occurred_on: "2025-10-05", cost: 150, status: "closed" },
    { incident_type: "citation", occurred_on: "2025-10-04", cost: null, status: "closed" }, // exactly a year ago: not counted
    { incident_type: "cargo_claim", occurred_on: "2024-01-01", cost: "200", status: "closed" },
  ];
  const s = summarizeHistory(rows, "2026-10-04");
  assert.equal(s.total, 4);
  assert.equal(s.last12Months, 2);
  assert.equal(s.open, 1);
  assert.equal(s.totalCost, 1350.1);
  assert.deepEqual(
    s.byType.map((t) => [t.type, t.count]),
    [["accident", 1], ["citation", 2], ["cargo_claim", 1]]
  );
  assert.deepEqual(summarizeHistory([], "2026-10-04"), { total: 0, open: 0, last12Months: 0, totalCost: 0, byType: [] });
});

test("pictures are stored as incident photos, everything else as other", () => {
  assert.equal(incidentFileType("image/jpeg"), "incident_photo");
  assert.equal(incidentFileType("image/png"), "incident_photo");
  assert.equal(incidentFileType("application/pdf"), "other");
});

test("reachable: sidebar, Insert menu, search, driver and truck pages", () => {
  assert.match(src("../../components/nav/nav-config.ts"), /label: "Safety Incidents", href: "\/safety"/);
  assert.match(src("../../components/desktop/menu-bar.tsx"), /"Report Safety Incident", href: "\/safety\/new"/);
  assert.match(src("../../components/nav/command-palette.tsx"), /"Safety Incidents", href: "\/safety"/);
  assert.match(src("../../app/(app)/drivers/[id]/page.tsx"), /<SafetyHistorySection driverId=\{id\} \/>/);
  assert.match(src("../../app/(app)/trucks/[id]/page.tsx"), /<SafetyHistorySection truckId=\{id\} \/>/);
});

test("uploads go one file per request and big photos are shrunk (hosting request limit)", () => {
  const ui = src("../../components/safety/incident-files.tsx");
  assert.match(ui, /SEND_LIMIT = 4 \* 1024 \* 1024/);
  assert.match(ui, /shrinkPhoto\(original\)/);
  const actions = src("../../app/(app)/safety/actions.ts");
  assert.match(actions, /entity_type: "safety_incident"/);
  assert.match(actions, /\$\{organizationId\}\/safety\/\$\{incidentId\}\//);
});
