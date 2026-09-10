// Regression: migration 0125 added loads.financial_dispatch_id ->
// dispatches.id, so PostgREST sees TWO dispatches<->loads relationships and
// every bare `.from("dispatches").select("... loads(...) ...")` (or nested
// `dispatches(loads(...))`) now 500s with PGRST201. Each such embed must
// name the operational FK: loads!dispatches_load_id_fkey (the load the
// dispatch is FOR -- never loads.financial_dispatch_id).
//
// This asserts every corrected query at the source, and the Dispatch Board
// Booked/Unassigned rules (shows booked loads with no active dispatch;
// LD-100024 -> dispatch ff50462b is excluded; nothing appears twice).

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const ROOT = new URL("../../../", import.meta.url); // repo root
const read = (rel) => readFileSync(new URL(rel, ROOT), "utf8");

// Files whose dispatches->loads embed was corrected in this sweep.
const CORRECTED = [
  "src/app/(app)/dispatch/board/page.tsx",
  "src/app/(app)/dispatch/actions.ts",
  "src/app/(app)/dispatch/route-actions.ts",
  "src/app/(app)/dispatch/exceptions/actions.ts",
  "src/app/(app)/advances/new/page.tsx",
  "src/app/(app)/tracking/page.tsx",
  "src/app/(app)/drivers/page.tsx",
  "src/lib/exceptions/sync.ts",
  "src/app/driver-portal/actions.ts",
  "src/app/driver-portal/history/page.tsx",
  "src/app/driver-portal/history/[dispatchId]/page.tsx",
  "src/lib/driver-portal/dashboard-data.ts",
  "src/components/drivers/trip-history-section.tsx",
  "src/components/tracking/live-map.tsx",
  "src/components/loads/share-external-profile-section.tsx",
  "src/lib/documents/belongs-to.ts",
];

test("every corrected file embeds loads via the named operational FK", () => {
  for (const rel of CORRECTED) {
    const src = read(rel);
    assert.match(
      src,
      /loads(:loads)?!dispatches_load_id_fkey\(/,
      `${rel}: must use loads!dispatches_load_id_fkey(...)`
    );
  }
});

test("no corrected file still has a bare ambiguous loads(...) embed in a dispatches context", () => {
  // A bare `loads(` that is NOT preceded by the `!dispatches_load_id_fkey`
  // hint and NOT part of a comment/other-table select. We approximate by
  // stripping comments + the hinted form, then asserting no `loads(` with a
  // column list that looks like the dispatch->load embed remains.
  const BARE = /(^|[^!])\bloads\((?:id|load_number|status|total_miles|commodity)/;
  for (const rel of CORRECTED) {
    let code = read(rel)
      .replace(/^[ \t]*\/\/.*$/gm, "")              // line comments
      .replace(/loads(:loads)?!dispatches_load_id_fkey\([^)]*\)/g, "OK"); // hinted embeds
    assert.doesNotMatch(code, BARE, `${rel}: still has a bare loads(...) embed`);
  }
});

test("the fix targets the OPERATIONAL relationship, not loads.financial_dispatch_id", () => {
  for (const rel of CORRECTED) {
    assert.doesNotMatch(
      read(rel),
      /loads!loads_financial_dispatch_id_fkey/,
      `${rel}: must not embed via the financial-controller FK`
    );
  }
});

test("dispatch board surfaces the query error instead of silently hiding all dispatches", () => {
  const src = read("src/app/(app)/dispatch/board/page.tsx");
  assert.match(src, /error:\s*dispatchesError/);
  assert.match(src, /dispatchesError\)\s*console\.error/);
});

// --- Booked / Unassigned column rules -------------------------------------

// Mirror of the board's server-side derivation (dispatch/board/page.tsx).
function bookedColumn(dispatches, bookedLoads) {
  const activeDispatchLoadIds = new Set(
    dispatches
      .filter((d) => !["delivered", "completed", "cancelled"].includes(d.status))
      .map((d) => d.load_id)
  );
  return bookedLoads.filter((l) => !activeDispatchLoadIds.has(l.id));
}

test("Booked column shows booked loads that have NO active dispatch", () => {
  const booked = bookedColumn(
    [{ id: "d1", status: "assigned", load_id: "L-other" }],
    [{ id: "L-1", load_number: "LD-1" }, { id: "L-2", load_number: "LD-2" }]
  );
  assert.deepEqual(booked.map((l) => l.load_number), ["LD-1", "LD-2"]);
});

test("LD-100024 (dispatch ff50462b = assigned) is EXCLUDED from the Booked column, appears once as its card", () => {
  const dispatches = [{ id: "ff50462b", status: "assigned", load_id: "463891ec" }];
  const bookedLoads = [{ id: "463891ec", load_number: "LD-100024" }, { id: "L-x", load_number: "LD-X" }];
  const booked = bookedColumn(dispatches, bookedLoads);
  assert.equal(booked.find((l) => l.id === "463891ec"), undefined, "LD-100024 must not be in Booked column");
  assert.deepEqual(booked.map((l) => l.load_number), ["LD-X"]);
  // and it IS present exactly once as a dispatch card
  assert.equal(dispatches.filter((d) => d.load_id === "463891ec").length, 1);
});

test("a booked load whose only dispatch is terminal (cancelled/delivered) DOES show in Booked", () => {
  for (const status of ["cancelled", "delivered", "completed"]) {
    const booked = bookedColumn(
      [{ id: "d-old", status, load_id: "L-1" }],
      [{ id: "L-1", load_number: "LD-1" }]
    );
    assert.deepEqual(booked.map((l) => l.id), ["L-1"], `${status} dispatch should not suppress the Booked card`);
  }
});

test("no load appears in both the Booked column and as an active dispatch card", () => {
  const dispatches = [
    { id: "d1", status: "assigned", load_id: "L-1" },
    { id: "d2", status: "en_route_to_delivery", load_id: "L-2" },
    { id: "d3", status: "cancelled", load_id: "L-3" },
  ];
  const bookedLoads = [
    { id: "L-1", load_number: "LD-1" },
    { id: "L-2", load_number: "LD-2" },
    { id: "L-3", load_number: "LD-3" },
    { id: "L-4", load_number: "LD-4" },
  ];
  const booked = bookedColumn(dispatches, bookedLoads);
  const activeCardLoadIds = new Set(
    dispatches.filter((d) => !["delivered", "completed", "cancelled"].includes(d.status)).map((d) => d.load_id)
  );
  for (const l of booked) assert.equal(activeCardLoadIds.has(l.id), false, `${l.load_number} double-listed`);
  assert.deepEqual(booked.map((l) => l.id).sort(), ["L-3", "L-4"]);
});
