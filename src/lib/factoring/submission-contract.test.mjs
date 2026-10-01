// Proposals 0154-0156 (F-08) -- application contract of factoring submission.
//
// Reads the invoice factoring action, the invoice page and the PROPOSED 0156 SQL as source (the same technique as the other compatibility tests: the app files import
// next/* aliases and cannot be imported under `node --test`). ZERO Supabase calls, ZERO DB, ZERO network. The SQL behaviour itself is proven by
// supabase/proposals/0154/tests.py on a disposable PostgreSQL; this file pins the CONTRACT between the action and the RPC so the two cannot drift apart.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (rel) => readFileSync(new URL(rel, import.meta.url), "utf8");
const stripComments = (src) => src.replace(/^[ \t]*\/\/.*$/gm, "");
const ACTION = stripComments(read("../../app/(app)/invoices/factoring-actions.ts"));
const PAGE = stripComments(read("../../app/(app)/invoices/[id]/page.tsx"));
const SQL0156 = readFileSync(new URL("../../../supabase/proposals/0156/proposed_0156.sql", import.meta.url), "utf8");
const SQL0140 = readFileSync(new URL("../../../supabase/migrations/0140_factoring_authorization_and_submission_safety.sql", import.meta.url), "utf8");
const returns = [...SQL0156.matchAll(/return pg_catalog\.jsonb_build_object\(([\s\S]*?)\);/g)].map((m) => m[1]);

test("every REJECTION the 0156 function can return is structured: success=false + a stable code + a human message (what the action surfaces)", () => {
  const rejections = returns.filter((r) => r.includes("'success', false"));
  assert.ok(rejections.length === 13, `expected 13 structured rejections, found ${rejections.length}`);
  for (const r of rejections) {
    assert.match(r, /'code', '[A-Z_]+'/);
    assert.match(r, /'message', '/);
  }
});

test("the only SUCCESS shape carries factored_invoice_id and status -- the exact keys submitInvoiceToFactor reads", () => {
  const ok = returns.filter((r) => r.includes("'success', true"));
  assert.equal(ok.length, 1);
  assert.match(ok[0], /'factored_invoice_id'/);
  assert.match(ok[0], /'status'/);
  assert.match(ACTION, /resolved\.data\.factored_invoice_id \|\| !resolved\.data\.status/);
  assert.match(ACTION, /factoredInvoiceId: resolved\.data\.factored_invoice_id, status: resolved\.data\.status/);
});

test("the disabled-by-default rejection is byte-identical to the 0140 one (code, snapshot_required, message) so the app's existing handling and UI wording stay valid", () => {
  const code = "CARRIER_INVOICE_SNAPSHOT_REQUIRED";
  const msg = "This invoice was created before carrier-specific financial snapshots were enabled. Review and reissue it through the new invoice workflow.";
  assert.ok(SQL0140.includes(code) && SQL0140.includes(msg));
  assert.ok(SQL0156.includes(`'code', '${code}', 'snapshot_required', true`));
  assert.ok(SQL0156.includes(msg));
  assert.ok(PAGE.includes(msg));
});

test("the action forwards the RPC's code and snapshot_required, and never chooses a relationship or a carrier itself (the database decides)", () => {
  assert.match(ACTION, /code: rpcResult\?\.code/);
  assert.match(ACTION, /snapshotRequired: rpcResult\?\.snapshot_required === true/);
  const body = ACTION.split("export async function submitInvoiceToFactor")[1].split("export async function")[0];
  assert.ok(!/carrier_id|carriers|is_default|factoring_relationships/.test(body), "submitInvoiceToFactor must not read or select carriers/relationships");
  assert.match(body, /supabase\.rpc\("submit_invoice_to_factor", \{\s*p_invoice_id: invoiceId,\s*p_relationship_id: relationshipId,?\s*\}\)/);
});

test("the action calls the RPC through the CALLER's own session (never service-role): the database authorizes by auth.uid()", () => {
  const body = ACTION.split("export async function submitInvoiceToFactor")[1].split("export async function")[0];
  assert.match(body, /await createClient\(\)/);
  assert.ok(!/service-role|createServiceRoleClient/i.test(body));
});

test("the 0156 function keeps the messages the action maps from exceptions (auth / role / not found / not eligible) verbatim from 0140", () => {
  for (const m of ["No organization on this account.", "You do not have permission to submit invoices for factoring.", "Invoice not found.", "This invoice is not eligible for factoring."]) {
    assert.ok(SQL0140.includes(m), `0140 lacks ${m}`);
    assert.ok(SQL0156.includes(m), `0156 lacks ${m}`);
  }
});

test("KNOWN GAP recorded (Owner decision D-08c): the invoice page still hides the submit control for every legacy invoice, so nothing in the UI can reach the RPC until a reviewed UI change follows the Owner's decisions", () => {
  assert.match(PAGE, /SNAPSHOT_REQUIRED_REASON/);
  const owner = readFileSync(new URL("../../../supabase/proposals/0156/OWNER_DECISIONS.md", import.meta.url), "utf8");
  assert.match(owner, /D-08c/);
  assert.match(owner, /keeps? .*submission.*disabled|DISABLED/i);
});

test("dispatch fees stay separate: the 0156 function never reads a dispatch-fee column and takes the face value from the invoice total alone", () => {
  assert.ok(!/dispatch_fee/i.test(SQL0156.replace(/--[^\n]*/g, "")));
  assert.match(SQL0156, /v_face_value := v_invoice\.total_amount;/);
});
