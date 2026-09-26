// Proposal 0157 (D-57) -- source-level CONTRACT of the issuance/reissue server actions, pages and components (they import next/* aliases and cannot be imported under `node --test`). Zero DB, zero network.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";

const read = (rel) => readFileSync(new URL(rel, import.meta.url), "utf8");
const strip = (s) => s.replace(/^[ \t]*\/\/.*$/gm, "").replace(/\/\*[\s\S]*?\*\//g, "");
const ACTIONS = strip(read("../../app/(app)/carrier-invoices/issuance-actions.ts"));
const LIFECYCLE = strip(read("../../components/carrier-invoices/carrier-invoice-lifecycle-panel.tsx"));
const NEWFORM = strip(read("../../components/carrier-invoices/new-carrier-invoice-form.tsx"));
const FPANEL = strip(read("../../components/carrier-invoices/carrier-invoice-factoring-panel.tsx"));
const DETAIL = strip(read("../../app/(app)/carrier-invoices/[id]/page.tsx"));
const NEWPAGE = strip(read("../../app/(app)/carrier-invoices/new/page.tsx"));
const SQL = read("../../../supabase/proposals/0157/proposed_0157.sql");

const RPC_PARAMS = {
  preview_carrier_invoice_issuance: ["p_carrier_id", "p_load_ids", "p_recipient_type", "p_recipient_id"],
  create_carrier_invoice_draft_from_loads: ["p_carrier_id", "p_load_ids", "p_recipient_type", "p_recipient_id", "p_idempotency_key"],
  mark_carrier_invoice_ready_for_issue: ["p_invoice_id", "p_expected_updated_at", "p_idempotency_key"],
  discard_carrier_invoice_draft: ["p_invoice_id", "p_expected_updated_at", "p_reason", "p_idempotency_key"],
  issue_prepared_carrier_invoice: ["p_invoice_id", "p_expected_updated_at", "p_reason", "p_idempotency_key"],
  preview_carrier_invoice_reissue: ["p_invoice_id"],
  reissue_carrier_invoice: ["p_invoice_id", "p_expected_updated_at", "p_reason", "p_idempotency_key"],
};

test("the actions call exactly the seven 0157 issuance RPCs with exactly the reviewed parameters, through the caller's own session (never service-role)", () => {
  for (const [rpc, params] of Object.entries(RPC_PARAMS)) {
    const m = ACTIONS.match(new RegExp(`supabase\\.rpc\\("${rpc}", \\{([^}]*)\\}\\)`));
    assert.ok(m, `${rpc} call not found`);
    const used = [...m[1].matchAll(/(p_[a-z_]+):/g)].map((x) => x[1]);
    assert.deepEqual(used, params, rpc);
    // the SQL signature has the same parameters (contract with the database)
    const sig = SQL.match(new RegExp(`create function public\\.${rpc}\\(([^)]*)\\)`));
    assert.ok(sig, `${rpc} not in the SQL`);
    assert.deepEqual([...sig[1].matchAll(/(p_[a-z_]+) /g)].map((x) => x[1]), params, `${rpc} SQL signature`);
  }
  assert.equal([...ACTIONS.matchAll(/supabase\.rpc\(/g)].length, 7);
  assert.ok(!/service-role|createServiceRoleClient|SUPABASE_SERVICE/i.test(ACTIONS));
});

test("NOTHING the client could substitute exists: no relationship / factor / routing / organization / fee / amount / total parameter anywhere in the actions", () => {
  assert.ok(!/relationship|factoring_company|factor_id|routing|organization_id|p_org|p_total|p_amount|p_fee|p_advance|p_reserve|noa_/i.test(ACTIONS.replace(/carrier_invoice_factoring/g, "")));
});

test("every action validates its input (and the idempotency key) BEFORE any request; every mutation passes the SaaS paywall check and refreshes the invoice pages on success only", () => {
  assert.match(ACTIONS, /const bad = validateIssuanceInput\(input\);\s*if \(bad\) return/);
  assert.equal([...ACTIONS.matchAll(/isValidWorkflowKey\(idempotencyKey\)/g)].length, 5);
  assert.equal([...ACTIONS.matchAll(/await checkOperationalAccess\(\)/g)].length, 5); // create, ready, discard, issue, reissue (previews are reads)
  assert.equal([...ACTIONS.matchAll(/if \(outcome\.ok\) refresh\(/g)].length, 5);
  assert.match(ACTIONS, /revalidatePath\("\/carrier-invoices"\)/);
  assert.match(ACTIONS, /revalidatePath\(`\/carrier-invoices\/\$\{id\}`\)/);
  assert.match(ACTIONS, /refresh\(invoiceId, outcome\.replacementInvoiceId\)/, "the reissue refreshes BOTH the original and the replacement");
});

test("a reason is required for issue / discard / reissue (trimmed, bounded) and a transport error never leaks a database message", () => {
  assert.equal([...ACTIONS.matchAll(/cleanReason\(reason\)/g)].length, 3);
  assert.match(ACTIONS, /trim\(\)\.length <= 500/);
  assert.match(ACTIONS, /code: "TRANSPORT", message: ISSUANCE_GENERIC_FAILURE/);
});

test("the pickers read through the caller's RLS-scoped session and are only conveniences: carriers (active), delivered loads of ONE carrier, bounded; the RPC re-validates", () => {
  assert.match(ACTIONS, /from\("carriers"\)/);
  assert.match(ACTIONS, /\.eq\("carrier_id", carrierId\)\.in\("status", \["delivered", "pod_received"\]\)/);
  assert.match(ACTIONS, /\.limit\(200\)/);
});

test("the new-invoice form: one carrier, that carrier's loads, a server preview BEFORE any draft, an explicit confirmation dialog, a per-confirmation key, an in-flight guard, mixed brokers refused", () => {
  assert.match(NEWFORM, /previewCarrierInvoiceIssuance\(/);
  assert.match(NEWFORM, /createCarrierInvoiceDraft\(/);
  assert.match(NEWFORM, /Confirm and create draft/);
  assert.match(NEWFORM, /keyRef\.current = newWorkflowKey\(\)/);
  assert.match(NEWFORM, /tryBegin\(guard\.current\)/);
  assert.match(NEWFORM, /guard\.current\.inFlight = false/);
  assert.match(NEWFORM, /disabled=\{busy\}/);
  assert.match(NEWFORM, /different brokers\/customers/);
  assert.ok(!/relationship|factoringCompany|setFactor|remittance/i.test(NEWFORM.replace(/issuanceConfirmationLines/g, "")), "no factor/relationship/routing field exists in the form");
  assert.match(NEWFORM, /issuanceConfirmationLines\(preview\)/);
});

test("the lifecycle panel: each step is a confirmed dialog with one key per opening, a required reason where recorded, an in-flight guard, the RPC's own safe code/message and a server refresh", () => {
  assert.match(LIFECYCLE, /keyRef\.current = newWorkflowKey\(\)/);
  assert.match(LIFECYCLE, /tryBegin\(guard\.current\)/);
  assert.match(LIFECYCLE, /guard\.current\.inFlight = false/);
  assert.match(LIFECYCLE, /role="alert"/);
  assert.match(LIFECYCLE, /router\.refresh\(\)/);
  assert.match(LIFECYCLE, /A reason is required/);
  for (const need of ["markCarrierInvoiceReady(invoiceId, updatedAt, key)", "issueCarrierInvoice(invoiceId, updatedAt, reason, key)", "discardCarrierInvoiceDraft(invoiceId, updatedAt, reason, key)", "reissueCarrierInvoice(invoiceId, updatedAt, reason, key)"]) assert.ok(LIFECYCLE.includes(need), need);
  assert.match(LIFECYCLE, /router\.push\(`\/carrier-invoices\/\$\{o\.replacementInvoiceId \?\? o\.invoiceId\}`\)/);
});

test("the reissue is offered with its drift explanation and its consequences (void with reason, same loads and total, CURRENT terms; refused with a submission or any payment); dispatch fees stay separate in the wording", () => {
  assert.match(LIFECYCLE, /driftSentence\(reissuePreview\.drift_dimensions\)/);
  assert.match(LIFECYCLE, /voids this invoice \(kept, with your reason\)/);
  assert.match(LIFECYCLE, /refused if any factoring submission exists or the invoice has any payment/);
  assert.match(LIFECYCLE, /Dispatch-service fees stay a separate receivable/);
});

test("the detail page: the factoring panel is rendered ONLY when lifecycleActions says the invoice is correctly issued; previews come from the database; the role only decides what is offered", () => {
  assert.match(DETAIL, /actions\.factoringPanel \? await getCarrierInvoiceFactoringPreview\(id\) : null/);
  assert.match(DETAIL, /\{actions\.factoringPanel \? <CarrierInvoiceFactoringPanel/);
  assert.match(DETAIL, /\.from\("carrier_invoices"\)/);
  assert.ok(!/from\("invoices"\)/.test(DETAIL));
  assert.match(DETAIL, /previewCarrierInvoiceReissue\(id\)/);
  assert.match(DETAIL, /reissuedTo/);
  assert.match(DETAIL, /reissuedFrom/);
  assert.match(DETAIL, /separate receivable/);
  assert.match(DETAIL, /never factored/);
});

test("the factoring panel: drift / direct-billing / uncontrolled issuance shows NO submit control and directs to the reissue workflow; the old 'relationship changed' warn-and-proceed note is gone (D-57d)", () => {
  assert.match(FPANEL, /state\.kind === "reissue_required"/);
  assert.match(FPANEL, /href="#reissue"/);
  assert.match(FPANEL, /Reissue required before factoring/);
  assert.ok(!/relationship_changed_since_issuance/.test(FPANEL + read("./carrier-invoice-submission.ts")));
  assert.ok(!/<select|<Select|combobox|RecordPicker|<input|<Input|<textarea|relationshipId|setRelationship/i.test(FPANEL));
  assert.ok(!/dispatch_fee|dispatch fee/i.test(FPANEL.replace(/dispatch-service fee/gi, "")));
});

test("the new-invoice page is offered only to owner / admin / dispatcher (convenience; the RPCs enforce the grant) and the LEGACY invoice pages are untouched", () => {
  assert.match(NEWPAGE, /role !== "owner" && role !== "admin" && role !== "dispatcher"\) redirect\("\/access-denied"\)/);
  const legacy = read("../../app/(app)/invoices/[id]/page.tsx") + read("../../app/(app)/invoices/factoring-actions.ts");
  assert.ok(!/issuance-actions|carrier-invoice-lifecycle-panel|issue_prepared_carrier_invoice|reissue_carrier_invoice/.test(legacy), "D-57g: legacy factored_invoices / invoices have no bridge to the carrier-invoice workflow");
  assert.ok(existsSync(new URL("../../app/(app)/carrier-invoices/new/page.tsx", import.meta.url)));
});
