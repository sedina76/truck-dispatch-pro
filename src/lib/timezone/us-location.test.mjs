// New Load: the stop Timezone is pre-selected from the stop's State / ZIP.
// Split states need the ZIP; straddling ZIP areas and ZIP-less split
// states are flagged "check" instead of silently guessed.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { suggestTimezone } from "./us-location.ts";
import { COMMON_TIMEZONES } from "./iana.ts";

const tz = (state, zip) => suggestTimezone(state, zip)?.timezone ?? null;
const certainty = (state, zip) => suggestTimezone(state, zip)?.certainty ?? null;
const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("single-zone states come from the state alone", () => {
  assert.equal(tz("GA"), "America/New_York");
  assert.equal(tz("il", ""), "America/Chicago"); // case-insensitive
  assert.equal(tz(" co "), "America/Denver");
  assert.equal(tz("AZ"), "America/Phoenix");
  assert.equal(tz("CA", "90210"), "America/Los_Angeles");
  assert.equal(tz("WA"), "America/Los_Angeles");
  assert.equal(tz("AK"), "America/Anchorage");
  assert.equal(tz("HI"), "Pacific/Honolulu");
  assert.equal(certainty("OH", "43215"), "exact");
});

test("split states use the ZIP to pick the zone", () => {
  assert.equal(tz("TX", "79901"), "America/Denver"); // El Paso
  assert.equal(tz("TX", "75201"), "America/Chicago"); // Dallas
  assert.equal(tz("FL", "32501"), "America/Chicago"); // Pensacola
  assert.equal(tz("FL", "33101"), "America/New_York"); // Miami
  assert.equal(tz("TN", "37902"), "America/New_York"); // Knoxville
  assert.equal(tz("TN", "37203"), "America/Chicago"); // Nashville
  assert.equal(tz("TN", "38103"), "America/Chicago"); // Memphis
  assert.equal(tz("KY", "42001"), "America/Chicago"); // Paducah
  assert.equal(tz("KY", "40202"), "America/New_York"); // Louisville
  assert.equal(tz("IN", "46402"), "America/Chicago"); // Gary
  assert.equal(tz("IN", "47708"), "America/Chicago"); // Evansville
  assert.equal(tz("IN", "46204"), "America/New_York"); // Indianapolis
  assert.equal(tz("ID", "83814"), "America/Los_Angeles"); // Coeur d'Alene
  assert.equal(tz("ID", "83702"), "America/Denver"); // Boise
  assert.equal(tz("OR", "97914"), "America/Denver"); // Ontario OR
  assert.equal(tz("OR", "97201"), "America/Los_Angeles"); // Portland
  assert.equal(tz("NE", "69361"), "America/Denver"); // Scottsbluff
  assert.equal(tz("NE", "68102"), "America/Chicago"); // Omaha
  assert.equal(tz("SD", "57701"), "America/Denver"); // Rapid City
  assert.equal(tz("ND", "58601"), "America/Denver"); // Dickinson
  assert.equal(tz("TX", "79901-1234"), "America/Denver"); // ZIP+4
  assert.equal(certainty("TX", "79901"), "exact");
});

test("split state without a full ZIP: best guess, flagged to check", () => {
  assert.equal(tz("TX"), "America/Chicago");
  assert.equal(certainty("TX"), "check");
  assert.equal(certainty("TX", "799"), "check"); // still typing the ZIP
  assert.equal(certainty("FL", ""), "check");
});

test("ZIP areas that straddle a zone line are flagged to check", () => {
  assert.equal(certainty("KS", "67735"), "check"); // Goodland area
  assert.equal(certainty("TN", "37343"), "check"); // Chattanooga outskirts
  assert.equal(certainty("NE", "69153"), "check"); // Ogallala
  assert.equal(certainty("AZ", "86515"), "check"); // Window Rock (Navajo Nation)
  assert.equal(certainty("AZ", "85004"), "exact"); // Phoenix
});

test("unknown or empty state gives no suggestion (the dropdown keeps its value)", () => {
  assert.equal(suggestTimezone("", "75201"), null);
  assert.equal(suggestTimezone("XX", ""), null);
  assert.equal(suggestTimezone(null, null), null);
});

test("every suggested zone is an option the dropdown has", () => {
  const options = new Set(COMMON_TIMEZONES.map((o) => o.value));
  const states = "AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY".split(" ");
  for (const st of states) {
    for (let p = 0; p < 1000; p += 1) {
      const zip = String(p).padStart(3, "0") + "01";
      const s = suggestTimezone(st, zip);
      assert.ok(s, `${st} should have a suggestion`);
      assert.ok(options.has(s.timezone), `${st} ${zip} -> ${s.timezone} is not in COMMON_TIMEZONES`);
    }
  }
});

test("New Load pickup, delivery and extra stops all use the auto dropdown", () => {
  const page = src("../../app/(app)/loads/new/page.tsx");
  assert.match(page, /<AutoTimezoneSelect name=\{`\$\{prefix\}_timezone`\} stateName=\{`\$\{prefix\}_state`\} zipName=\{`\$\{prefix\}_postal_code`\}/);
  const extra = src("../../components/loads/additional-stops-fields.tsx");
  assert.match(extra, /stateName=\{`extra_stops\[\$\{stop\.key\}\]\[state\]`\}/);
  assert.match(extra, /zipName=\{`extra_stops\[\$\{stop\.key\}\]\[postal_code\]`\}/);
  const select = src("../../components/loads/auto-timezone-select.tsx");
  assert.match(select, /e\.nativeEvent\.isTrusted/, "only a real pick by the dispatcher locks the choice");
});
