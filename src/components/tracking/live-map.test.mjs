// Tracking map popup XSS guard.
//
// live-map.tsx builds each driver popup as an HTML string and hands it to
// maplibre's Popup.setHTML(). Driver name, truck unit, load number and raw
// dispatch status are user-entered, so every one of them must go through
// escapeHtml() -- otherwise a value like `<img src=x onerror=...>` runs as
// script in every dispatcher's browser that opens the Tracking map.
//
// live-map.tsx imports maplibre-gl (browser-only) and app aliases, so it
// cannot be imported under `node --test`. Same technique as the rest of
// this codebase: read it as source and assert the contract by text. The
// escapeHtml body is evaluated in isolation to check its actual output.
//
// ZERO DB. ZERO network.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SRC = readFileSync(new URL("./live-map.tsx", import.meta.url), "utf8");

function popupSource() {
  const start = SRC.indexOf("function popupHtml(");
  assert.ok(start >= 0, "popupHtml not found");
  const end = SRC.indexOf("\nexport function LiveMap", start);
  return SRC.slice(start, end);
}

function loadEscapeHtml() {
  const m = SRC.match(/export function escapeHtml\(value: unknown\): string \{([\s\S]*?)\n\}/);
  assert.ok(m, "escapeHtml helper not found");
  return new Function("value", m[1]);
}

test("map popup: escapeHtml neutralises HTML/script in user-entered values", () => {
  const escapeHtml = loadEscapeHtml();
  assert.equal(
    escapeHtml(`<img src=x onerror="alert('x')">&`),
    "&lt;img src=x onerror=&quot;alert(&#39;x&#39;)&quot;&gt;&amp;",
  );
  assert.equal(escapeHtml(null), "");
  assert.equal(escapeHtml(undefined), "");
  assert.equal(escapeHtml("Unit 42"), "Unit 42");
});

test("map popup: every user-entered field is escaped before setHTML", () => {
  const popup = popupSource();
  for (const field of ["driverName", "truckUnit", "loadNumber"]) {
    assert.match(popup, new RegExp(`escapeHtml\\(marker\\.${field}\\)`), `${field} must be escaped`);
    assert.doesNotMatch(popup, new RegExp(`\\$\\{marker\\.${field}\\}`), `${field} must never be interpolated raw`);
  }
  assert.match(popup, /escapeHtml\(statusLabel\)/);
  assert.doesNotMatch(popup, /\$\{statusLabel\}/);
  assert.match(popup, /\/dispatch\/\$\{encodeURIComponent\(marker\.dispatchId\)\}/);
});

test("map popup: setHTML is only ever fed by popupHtml()", () => {
  const calls = SRC.match(/\.setHTML\(([^)]*\))\)/g) ?? [];
  assert.ok(calls.length > 0);
  for (const call of calls) assert.match(call, /\.setHTML\(popupHtml\(/);
});
