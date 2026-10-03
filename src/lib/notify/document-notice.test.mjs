// What the office bell says when a driver uploads a document.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { driverDocumentNotice } from "./document-notice.ts";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("POD and other document wording", () => {
  assert.deepEqual(driverDocumentNotice("pod", "LD-100041", "Dana One"), {
    title: "POD uploaded -- Load LD-100041",
    body: "Dana One uploaded a proof of delivery. Review and verify it so the load can be billed.",
  });
  assert.deepEqual(driverDocumentNotice("lumper_receipt", "LD-1", null), { title: "Lumper receipt uploaded -- Load LD-1", body: "The driver uploaded a lumper receipt." });
  assert.equal(driverDocumentNotice("weird", null, " ").title, "Document uploaded -- a load");
});

test("both driver upload paths notify the office, and the bell opens the load", () => {
  assert.match(src("../../app/api/driver-portal/upload-pod/route.ts"), /notifyOfficeOfDriverDocument\(supabase, \{[\s\S]*documentType: "pod"/);
  assert.match(src("../../app/driver-portal/actions.ts"), /export async function uploadTripDocument[\s\S]*?notifyOfficeOfDriverDocument\(supabase, \{[\s\S]*?documentType,/);
  const helper = src("./office-notify.ts");
  assert.match(helper, /\.in\("role", \["owner", "admin", "dispatcher", "accountant"\]\)\.eq\("is_active", true\)/);
  assert.match(helper, /entity_type: "load" as const/);
  assert.match(src("../../components/nav/notifications-menu.tsx"), /n\.entity_type === "load" && n\.entity_id \? \([\s\S]*?href=\{`\/loads\/\$\{n\.entity_id\}`\}/);
});
