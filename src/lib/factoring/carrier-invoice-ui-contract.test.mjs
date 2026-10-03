// Proposal 0157 -- source-level CONTRACT of the carrier-invoice factoring UI/actions (the app files import next/* aliases and cannot be imported under `node --test`). Zero DB, zero network.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";

const read = (rel) => readFileSync(new URL(rel, import.meta.url), "utf8");
const strip = (s) => s.replace(/^[ \t]*\/\/.*$/gm, "").replace(/\/\*[\s\S]*?\*\//g, "");
const ACTIONS = strip(read("../../app/(app)/carrier-invoices/factoring-actions.ts"));
const PANEL = strip(read("../../components/carrier-invoices/carrier-invoice-factoring-panel.tsx"));
const PAGE = strip(read("../../app/(app)/carrier-invoices/[id]/page.tsx"));
const LEGACY_PAGE = read("../../app/(app)/invoices/[id]/page.tsx");
const LEGACY_ACTIONS = read("../../app/(app)/invoices/factoring-actions.ts");

test("the actions call only the two 0157 RPCs, through the caller's own session (never service-role), passing ONLY the invoice id (+ the idempotency key)", () => {
  assert.match(ACTIONS, /supabase\.rpc\("preview_carrier_invoice_factoring", \{ p_carrier_invoice_id: carrierInvoiceId \}\)/);
  assert.match(ACTIONS, /supabase\.rpc\("submit_carrier_invoice_to_factor", \{ p_carrier_invoice_id: carrierInvoiceId, p_idempotency_key: idempotencyKey \}\)/);
  assert.ok(!/service-role|createServiceRoleClient|SUPABASE_SERVICE/i.test(ACTIONS));
  assert.ok(!/relationship|factoring_company|carrier_id|p_relationship_id/i.test(ACTIONS.replace(/preview_carrier_invoice_factoring|submit_carrier_invoice_to_factor/g, "")), "no relationship/factor/carrier parameter may exist in the actions");
});

test("the submit action validates the idempotency key before any request and revalidates the invoice pages on success only", () => {
  assert.match(ACTIONS, /if \(!isValidIdempotencyKey\(idempotencyKey\)\) return/);
  assert.match(ACTIONS, /if \(outcome\.ok\) \{\s*revalidatePath\(`\/carrier-invoices\/\$\{carrierInvoiceId\}`\)/);
});

test("the panel has NO factor/relationship picker (no select, no combobox, no relationship input) and never accepts substitution", () => {
  assert.ok(!/<select|<Select|combobox|RecordPicker|<input|<Input|<textarea|relationshipId|setRelationship/i.test(PANEL));
  assert.match(PANEL, /cannot be changed here/);
  assert.match(PANEL, /confirmationLines\(state\.preview\)/);
});

test("the panel requires a deliberate confirmation, blocks duplicate/concurrent submissions and refreshes state after success", () => {
  assert.match(PANEL, /Confirm submission/);
  assert.match(PANEL, /tryBeginSubmit\(guard\.current\)/);
  assert.match(PANEL, /disabled=\{busy\}/);
  assert.match(PANEL, /guard\.current\.inFlight = false/);
  assert.match(PANEL, /router\.refresh\(\)/);
  assert.match(PANEL, /keyRef\.current = newIdempotencyKey\(\)/);
});

test("the panel shows the RPC's exact safe code and message (role=alert) and only renders for an eligible or visibly blocked state", () => {
  assert.match(PANEL, /role="alert"/);
  assert.match(PANEL, /error\.code/);
  assert.match(PANEL, /error\.message/);
  assert.match(PANEL, /state\.kind === "hidden"\) return null/);
});

test("the carrier-invoice page reads carrier_invoices (never the legacy invoices table) and gets the preview from the database", () => {
  assert.match(PAGE, /\.from\("carrier_invoices"\)/);
  assert.ok(!/from\("invoices"\)/.test(PAGE));
  assert.match(PAGE, /getCarrierInvoiceFactoringPreview\(id\)/);
});

test("LEGACY invoices are NOT offered for factoring: neither the legacy page nor the legacy action reference the carrier-invoice action/panel, and the legacy page keeps its blocked state", () => {
  assert.ok(!/carrier-invoice-factoring-panel|carrier-invoices\/factoring-actions|submit_carrier_invoice_to_factor|preview_carrier_invoice_factoring/.test(LEGACY_PAGE + LEGACY_ACTIONS));
  assert.match(LEGACY_PAGE, /SNAPSHOT_REQUIRED_REASON/);
});

test("dispatch fees stay separate: nothing in the app layer for carrier-invoice factoring mentions or computes a dispatch fee", () => {
  assert.ok(!/dispatch_fee|dispatch fee/i.test(ACTIONS + PANEL.replace(/dispatch-service fee/gi, "")));
  assert.ok(existsSync(new URL("../../../supabase/proposals/0157/proposed_0157.sql", import.meta.url)));
  assert.match(read("../../../supabase/proposals/0157/proposed_0157.sql"), /dispatch_service_fee/);
});

test("authorization is enforced by the database, not the UI: the pilot submit SQL requires owner/admin; grants allow preview/preparation only and fails closed on a null identity", () => {
  const sql = read("../../../supabase/proposals/0157/proposed_0157.sql");
  assert.match(sql, /if v_uid is null then return pg_catalog\.jsonb_build_object\('success', false, 'code', 'FORBIDDEN'/);
  assert.match(sql, /v_role = 'dispatcher' and exists \(select 1 from public\.carrier_factoring_submitter_grants_0157/);
  const submit = sql.split("create function public.submit_carrier_invoice_to_factor(")[1].split("\n$fn$;")[0];
  assert.match(submit, /p\.role::text in \('owner', 'admin'\)/);
  assert.ok(!submit.includes("'owner', 'admin', 'dispatcher'"));
  assert.ok(submit.indexOf("'NOT_FOUND'") < submit.indexOf("p.role::text in ('owner', 'admin')"));
  assert.ok(submit.indexOf("p.role::text in ('owner', 'admin')") < submit.indexOf("idempotent_replay"));
  assert.match(ACTIONS, /if \(!isCarrierInvoicePilotOperator\(profile\?\.role\)\) return/);
});

// Execute the real server actions with local dependencies; no Next server or network.
// This verifies early refusals actually prevent RPC calls, including direct action invocation.
import ts from "typescript";
import * as issuance from "./carrier-invoice-issuance.ts";
import * as submission from "./carrier-invoice-submission.ts";

function actionHarness(file, role, { exists = true, authenticated = true, billing = true } = {}) {
  const calls = [];
  const supabase = {
    auth: { getUser: async () => ({ data: { user: authenticated ? { id: "caller" } : null } }) },
    from(table) {
      return { select() { return this; }, eq() { return this; }, async maybeSingle() {
        return { data: table === "profiles" ? (role == null ? null : { role }) : (exists ? { id: "invoice" } : null) };
      } };
    },
    async rpc(name) { calls.push(name); return { data: { success: true, status: "submitted", submission_id: "submission" }, error: null }; },
  };
  const dependencies = {
    "next/cache": { revalidatePath() {} },
    "@/lib/supabase/server": { createClient: async () => supabase },
    "@/lib/billing/operational-access": { checkOperationalAccess: async () => ({ ok: billing }) },
    "@/lib/factoring/carrier-invoice-issuance": issuance,
    "@/lib/factoring/carrier-invoice-submission": submission,
    // auto-creates the carrier's billing link with the broker before preview/draft (not used by issue/reissue/submit)
    "@/lib/carrier-invoices/party-link": { ensureCarrierPartyLink: async () => null },
  };
  const code = ts.transpileModule(read(`../../app/(app)/carrier-invoices/${file}`), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const exports = {};
  new Function("require", "exports", code)((name) => {
    assert.ok(name in dependencies, `Unexpected dependency: ${name}`);
    return dependencies[name];
  }, exports);
  return { actions: exports, calls };
}

const invoiceId = "c1000000-0000-0000-0000-000000000001";
const pilotActions = [
  ["factoring-actions.ts", "submitCarrierInvoiceToFactor", [invoiceId, "cif-12345678-abcd"], "submit_carrier_invoice_to_factor"],
  ["issuance-actions.ts", "issueCarrierInvoice", [invoiceId, "2026-09-21T10:00:00Z", "pilot", "cif-12345678-abcd"], "issue_prepared_carrier_invoice"],
  ["issuance-actions.ts", "reissueCarrierInvoice", [invoiceId, "2026-09-21T10:00:00Z", "pilot", "cif-12345678-abcd"], "reissue_carrier_invoice"],
];
for (const [file, action, args, rpc] of pilotActions) {
  test(`${action}: only owner/admin reach the mutation RPC; dispatcher, accountant, driver, viewer and missing profile are refused`, async () => {
    for (const role of ["owner", "admin", "dispatcher", "accountant", "driver", "viewer", null]) {
      const h = actionHarness(file, role);
      const result = await h.actions[action](...args);
      if (role === "owner" || role === "admin") assert.deepEqual(h.calls, [rpc]);
      else { assert.equal(result.code, "FORBIDDEN", String(role)); assert.deepEqual(h.calls, []); }
    }
  });
  test(`${action}: missing/foreign invoice is NOT_FOUND; missing session and billing denial prevent writes`, async () => {
    for (const role of ["owner", "dispatcher", "accountant"]) {
      const h = actionHarness(file, role, { exists: false });
      assert.equal((await h.actions[action](...args)).code, "NOT_FOUND");
      assert.deepEqual(h.calls, []);
    }
    for (const opts of [{ authenticated: false }, { billing: false }]) {
      const h = actionHarness(file, "owner", opts);
      assert.equal((await h.actions[action](...args)).code, "FORBIDDEN");
      assert.deepEqual(h.calls, []);
    }
  });
}
