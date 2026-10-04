import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { formatPhone } from "./phone.ts";

test("phone numbers read like phone numbers", () => {
  assert.equal(formatPhone("6193650072"), "(619) 365-0072");
  assert.equal(formatPhone("+1 619-365-0072"), "(619) 365-0072");
  assert.equal(formatPhone("(619) 365 0072"), "(619) 365-0072");
  assert.equal(formatPhone("+44 20 7946 0958"), "+44 20 7946 0958", "non-US left as stored");
  assert.equal(formatPhone(null), "--");
});

test("Driver & Equipment: formatted phone, truck details on the Truck row, truck/trailer link to their pages", () => {
  const drawer = readFileSync(new URL("../../components/dispatch/dispatch-drawer.tsx", import.meta.url), "utf8");
  assert.match(drawer, /<Row label="Driver Phone" value=\{formatPhone\(data\.driver\?\.phone\)\} \/>/);
  assert.ok(!drawer.includes('label="Tractor Type"'));
  assert.match(drawer, /href=\{`\/trucks\/\$\{data\.truck\.id\}`\}/);
  assert.match(drawer, /href=\{`\/trailers\/\$\{data\.trailer\.id\}`\}/);
});

test("Communication: formatted phone, 'Driver Status', no second 'Communication' heading", () => {
  const panel = readFileSync(new URL("../../components/dispatch/communication-panel.tsx", import.meta.url), "utf8");
  assert.match(panel, /driver\?\.phone \? formatPhone\(driver\.phone\) : "Not on file"/);
  assert.match(panel, />Call &amp; Message History</);
  assert.ok(!panel.includes(">Current Status<"));
  assert.match(panel, /href=\{`tel:\$\{driver\.phone\}`\}/, "the call link still dials the stored number");
});
