// Faster pages: "who is signed in / which company" is asked once per request
// and shared, the layout's two lookups run side by side, and a loading
// screen shows the moment a link is clicked.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("identity lookups are per-request cached (never across requests)", () => {
  const s = src("./session.ts");
  assert.match(s, /import \{ cache \} from "react";/);
  assert.match(s, /export const getSessionUser = cache\(/);
  assert.match(s, /export const getSessionProfile = cache\(/);
  assert.match(s, /supabase\.auth\.getUser\(\)/, "still verified with Supabase Auth");
});

test("layout, requireRole and getCurrentOrgId share them", () => {
  const layout = src("../../app/(app)/layout.tsx");
  assert.match(layout, /const \[profile, \{ data: notifications \}\] = await Promise\.all\(\[/);
  assert.match(src("./require-role.ts"), /const profile = await getSessionProfile\(\);/);
  const records = src("../actions/records.ts");
  assert.match(records, /const cached = await getSessionOrgId\(\);/);
  assert.match(records, /if \(cached\.id && !cached\.error\) return cached\.id;/, "a miss is asked again fresh");
});

test("a loading screen covers every page in the app", () => {
  assert.match(src("../../app/(app)/loading.tsx"), /export default function Loading\(\)/);
});
