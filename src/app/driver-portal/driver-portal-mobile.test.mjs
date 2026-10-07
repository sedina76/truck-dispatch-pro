// Driver Portal: Forgot PIN, phone-number matching, the lockout fix, and
// phone/tablet friendliness.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const sql = src("../../../supabase/migrations/0172_driver_portal_pin_reset.sql");

test("sign-in screen: Forgot PIN link, phone-friendly fields, phone remembered (never the PIN)", () => {
  const login = src("./login/page.tsx");
  assert.match(login, /href=\{`\/driver-portal\/forgot-pin/);
  assert.match(login, /inputMode="numeric"/);
  assert.match(login, /rememberPhone\(phone\)/);
  assert.doesNotMatch(login, /rememberPhone\(pin\)|localStorage/, "PIN is never stored");
  assert.match(src("../../lib/driver-portal/ui.ts"), /h-12 .*text-base/, "48px fields, 16px text");
});

test("forgot PIN request: same answer whether or not the number exists; office always told", () => {
  const r = src("../api/driver-portal/pin-reset/request/route.ts");
  assert.equal((r.match(/return NextResponse\.json\(GENERIC\)/g) ?? []).length, 3, "every outcome returns the identical generic response");
  assert.match(r, /if \(row\.email && EMAIL_PROVIDER_CONFIGURED\)/);
  assert.match(r, /notifyOfficeOfPinResetRequest\(supabase, \{ organizationId: row\.organization_id, driverId: row\.driver_id, driverName, emailed \}\)/);
  assert.doesNotMatch(r, /json\(\{[^}]*code/, "the code is never sent back to the browser");
});

test("forgot PIN confirm: reads the returned error, signs the driver in on success", () => {
  const r = src("../api/driver-portal/pin-reset/confirm/route.ts");
  assert.match(r, /row\.error/);
  assert.match(r, /if \(pin !== confirm\)/);
  assert.match(r, /await createDriverPortalSession\(row\.driver_id, row\.organization_id/);
});

test("0172: codes hashed, 15 min, 5 tries, 3 per hour, server-only, revoked logins can't reset", () => {
  assert.match(sql, /crypt\(v_code, gen_salt\('bf'\)\)/);
  assert.match(sql, /now\(\) \+ interval '15 minutes'/);
  assert.match(sql, /v_reset\.attempts >= 5/);
  assert.match(sql, /if v_recent < 3 then/);
  assert.match(sql, /if v_cred\.driver_id is null or not v_cred\.is_active then\s+return;/);
  assert.match(sql, /revoke all on function public\.driver_portal_begin_pin_reset\(text\) from public, anon, authenticated;/);
  assert.match(sql, /revoke all on function public\.driver_portal_finish_pin_reset\(text, text, text\) from public, anon, authenticated;/);
  assert.match(sql, /revoke all on public\.driver_portal_pin_resets from anon, authenticated;/);
  assert.match(sql, /delete from public\.driver_portal_sessions s where s\.driver_id = v_cred\.driver_id;/, "other sessions end on reset");
});

test("0172: phone typed any way matches, but two drivers with the same digits are never guessed", () => {
  assert.match(sql, /regexp_replace\(coalesce\(p_phone, ''\), '\\D', '', 'g'\)/);
  assert.match(sql, /if v_count <> 1 then\s+return null;/);
});

test("0172 lockout fix: a wrong PIN is saved (returned, not raised and rolled back)", () => {
  const verify = sql.slice(sql.indexOf("create or replace function public.verify_driver_portal_login"), sql.indexOf("create table if not exists public.driver_portal_pin_resets"));
  assert.match(verify, /failed_attempts \+ 1 >= 5 then now\(\) \+ interval '15 minutes'/);
  assert.doesNotMatch(verify, /where driver_portal_credentials\.driver_id = v_cred\.driver_id;\s+raise exception 'invalid_credentials'/);
  assert.match(verify, /return;\s+end if;/);
});

test("phone & tablet: no zoom-on-tap, safe areas, wider tablet column, no tab bar before sign-in", () => {
  const css = src("../globals.css");
  assert.match(css, /\.driver-portal input[^{]*,\s*\.driver-portal select,\s*\.driver-portal textarea \{\s*font-size: 16px;/);
  const layout = src("./layout.tsx");
  assert.match(layout, /viewportFit: "cover"/);
  assert.match(layout, /className="driver-portal /);
  assert.match(layout, /env\(safe-area-inset-bottom\)/);
  assert.match(layout, /md:max-w-2xl/);
  const nav = src("../../components/driver-portal/bottom-nav.tsx");
  assert.match(nav, /pathname\.startsWith\("\/driver-portal\/forgot-pin"\)/);
  assert.match(nav, /pb-\[env\(safe-area-inset-bottom\)\]/);
});
