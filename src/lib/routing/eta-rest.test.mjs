// Long-haul ETAs include the breaks and rests a solo driver must take.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { addRequiredRest, etaIncludesRest } from "./risk.ts";

const h = 3600;
const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("short trips are unchanged; 8 h+ adds a 30 min break; past 11 h adds a 10 h rest", () => {
  assert.equal(addRequiredRest(0), 0);
  assert.equal(addRequiredRest(5 * h), 5 * h);
  assert.equal(addRequiredRest(8 * h), 8 * h);
  assert.equal(addRequiredRest(9 * h), 9.5 * h);
  assert.equal(addRequiredRest(11 * h), 11.5 * h);
  assert.equal(addRequiredRest(12 * h), 11.5 * h + 10 * h + 1 * h);
  // the Minneapolis -> West Valley City load: ~21 h 50 min of driving
  const drive = 21 * h + 50 * 60;
  assert.equal(addRequiredRest(drive), 11.5 * h + 10 * h + (10 * h + 50 * 60) + 0.5 * h);
  // three shifts
  assert.equal(addRequiredRest(30 * h), (11.5 + 10 + 11.5 + 10 + 8) * h);
});

test("the ETA uses it, keeps pure driving time stored, and says so on screen", () => {
  const ev = src("./evaluate-route.ts");
  assert.match(ev, /getTime\(\) \+ addRequiredRest\(result\.durationSeconds\) \* 1000/);
  assert.match(ev, /route_duration_seconds: Math\.round\(result\.durationSeconds\)/);
  assert.ok(etaIncludesRest(9 * h) && !etaIncludesRest(2 * h) && !etaIncludesRest(null));
  assert.match(src("../../components/dispatch/dispatch-drawer.tsx"), /ETA includes required breaks and 10 h rests for a solo driver/);
});
