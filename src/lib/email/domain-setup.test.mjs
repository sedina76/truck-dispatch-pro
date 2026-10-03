// Email & Sending Domain: removed domains can be set up again; DNS table readable and copyable.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { addDomainDecision, dnsRecordStatusLabel } from "./domain-setup.ts";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("re-adding a REMOVED domain reactivates it instead of 'already added'", () => {
  assert.deepEqual(addDomainDecision(null, "org1"), { action: "create" });
  assert.deepEqual(addDomainDecision({ organization_id: "org1", disabled_at: "2026-10-01T00:00:00Z" }, "org1"), { action: "reactivate" });
  assert.deepEqual(addDomainDecision({ organization_id: "org1", disabled_at: null }, "org1"), { action: "refuse", error: "This sending domain is already added to your organization." });
  assert.deepEqual(addDomainDecision({ organization_id: "org2", disabled_at: null }, "org1"), { action: "refuse", error: "This sending domain is already in use by another account." });
});

test("DNS record statuses in plain words", () => {
  assert.equal(dnsRecordStatusLabel("not_started"), "Not checked yet");
  assert.equal(dnsRecordStatusLabel("pending"), "Checking");
  assert.equal(dnsRecordStatusLabel("failed"), "Not found");
  assert.equal(dnsRecordStatusLabel("temporary_failure"), "Retrying");
  assert.equal(dnsRecordStatusLabel(undefined), "Not checked yet");
  assert.equal(dnsRecordStatusLabel("something_new"), "Something new");
});

test("add action reactivates the kept row with fresh provider records", () => {
  const actions = read("../../app/(app)/settings/email/actions.ts");
  assert.match(actions, /addDomainDecision\(existingGlobal, organizationId\)/);
  assert.match(actions, /decision\.action === "reactivate"[\s\S]*?disabled_at: null,[\s\S]*?\.eq\("id", existingGlobal\.id\)/);
});

test("page: removed domains listed separately with 'Set up again'; DNS values full + copy; instructions", () => {
  const ui = read("../../app/(app)/settings/email/email-settings-client.tsx");
  assert.match(ui, /const active = domains\.filter\(\(d\) => !d\.disabled_at\);/);
  assert.match(ui, /<RemovedDomains domains=\{removed\}/);
  assert.match(ui, /Set up again/);
  assert.match(ui, /<CopyButton value=\{r\.value\} label="value" \/>/);
  assert.match(ui, /<CopyButton value=\{r\.name\} label="name" \/>/);
  assert.doesNotMatch(ui, /max-w-\[280px\] truncate/);
  assert.match(ui, /dnsRecordStatusLabel\(r\.status\)/);
  assert.match(ui, /is\s+managed \(for example GoDaddy, Namecheap or Cloudflare\)/);
});
