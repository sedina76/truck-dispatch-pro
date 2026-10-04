// Drivers show on the live map as a truck badge (status color, truck number
// underneath), centered on the GPS point -- not a plain dot.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const map = readFileSync(new URL("./live-map.tsx", import.meta.url), "utf8");

test("truck badge replaces the dot, keeps the status colors, updates in place", () => {
  assert.match(map, /const el = buildTruckMarkerElement\(markerColor\(marker\), marker\.truckUnit\);/);
  assert.match(map, /updateTruckMarkerElement\(existing\.getElement\(\), markerColor\(marker\), marker\.truckUnit\);/);
  assert.match(map, /badge\.innerHTML = TRUCK_SVG;/);
  assert.match(map, /new maplibregl\.Marker\(\{ element: el, anchor: "top", offset: \[0, -15\] \}\)/);
  assert.ok(!/el\.style\.borderRadius = "50%"/.test(map), "no more round dot for drivers");
  assert.match(map, /label\.textContent = unit \?\? "";/, "textContent, never HTML, for the truck number");
});
