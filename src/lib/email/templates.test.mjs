// Invitation / portal-access emails: a clear button instead of a raw
// 64-character link, safe HTML, and a clean plain-text version.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { carrierInvitationEmail, driverInvitationEmail, driverPortalAccessEmail, renderEmailHtml, renderEmailText } from "./templates.ts";

const URL_ = "https://truck-dispatch-pro.vercel.app/carrier-onboarding/" + "a".repeat(64);

test("carrier invitation: button, short readable copy, link only as a small fallback", () => {
  const e = carrierInvitationEmail({ orgName: "Kali Freights LLC", contactName: "Ryan Smith", url: URL_, expiresInDays: 14 });
  assert.equal(e.subject, "Kali Freights LLC invited you to set up as a carrier");
  const html = renderEmailHtml("Kali Freights LLC", e.layout);
  assert.match(html, />Start carrier setup<\/a>/);
  assert.match(html, /Hi Ryan,/);
  assert.match(html, /expires in 14 days/);
  assert.match(html, /Button not working\? Copy and paste this link/);
  // the long link appears only as the button href + the one small fallback
  assert.equal(html.split(URL_).length - 1, 3); // button href, fallback href, fallback text
  // plain text: same structure, link on its own line under a label
  assert.match(e.text, /Start carrier setup:\nhttps:/);
  assert.match(e.text, /- Certificate of Insurance/);
});

test("resend wording says the old link no longer works", () => {
  const c = carrierInvitationEmail({ orgName: "Kali", contactName: null, url: URL_, expiresInDays: 14, resend: true });
  assert.match(c.text, /Any earlier link we sent no longer works/);
  assert.match(c.text, /^Hello,/);
  const d = driverInvitationEmail({ carrierName: "Kali", firstName: "Sedina", url: URL_, expiresInDays: 14, resend: true });
  assert.equal(d.subject, "Your new driver onboarding link from Kali");
});

test("driver invitation names the carrier and lists what to have ready", () => {
  const d = driverInvitationEmail({ carrierName: "Kali Freights LLC", firstName: "Sedina", url: URL_, expiresInDays: 14 });
  assert.equal(d.subject, "Kali Freights LLC invited you to drive with them");
  assert.match(d.text, /- Your CDL/);
  assert.match(renderEmailHtml("Org", d.layout), />Start driver onboarding<\/a>/);
});

test("driver portal access shows phone + PIN in a box and a portal button", () => {
  const a = driverPortalAccessEmail({ orgName: "Kali", firstName: "Sedina Ali", phone: "312-555-0142", pin: "482913", portalUrl: "https://x.example/driver-portal" });
  const html = renderEmailHtml("Kali", a.layout);
  assert.match(html, /PIN<\/td><td[^>]*>482913</);
  assert.match(html, />Open the Driver Portal<\/a>/);
  assert.match(a.text, /Phone: 312-555-0142\nPIN: 482913/);
  assert.match(a.text, /^Hi Sedina,/);
});

test("everything dynamic is escaped and only http(s) links become buttons", () => {
  const layout = { heading: "<b>x</b>", intro: ['"><script>alert(1)</script>'], action: { label: "Go", url: "javascript:alert(1)" } };
  const html = renderEmailHtml("<Org>", layout);
  assert.doesNotMatch(html, /<script>/);
  assert.doesNotMatch(html, /href="javascript:/);
  assert.match(html, /&lt;Org&gt;/);
  assert.match(renderEmailText(layout), /Go:\njavascript:alert\(1\)/); // text part is inert
});

test("all three invitation/access emails are sent with the branded layout", () => {
  const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
  const carriers = src("../../app/(app)/carriers/onboarding/actions.ts");
  assert.equal((carriers.match(/\.\.\.carrierInvitationEmail\(/g) ?? []).length, 2);
  const drivers = src("../../app/(app)/drivers/applications/actions.ts");
  assert.equal((drivers.match(/\.\.\.driverInvitationEmail\(/g) ?? []).length, 2);
  assert.match(drivers, /\.\.\.driverPortalAccessEmail\(/);
  // and the layout reaches the provider
  assert.match(src("./send-pipeline.ts"), /layout: args\.layout,/);
  assert.match(src("./provider.ts"), /args\.layout \? renderEmailHtml\(args\.organizationName, args\.layout\)/);
});
