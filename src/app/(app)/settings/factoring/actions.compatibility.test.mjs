// Phase 3B.1.3 -- carrier-scoped factoring application compatibility.
//
// actions.ts imports "next/cache", "@/lib/supabase/server" (which itself
// imports "next/headers"), and other app-only aliases, so it cannot be
// imported directly under `node --test` (same constraint documented in
// src/lib/billing/operational-access.test.mjs). This reads it -- and its
// sibling default-relationship.ts / page.tsx / the invoice detail page --
// as source and asserts the contract by text, the same technique already
// established in this codebase.
//
// ZERO Stripe/Supabase calls. ZERO DB. ZERO network.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (rel) => readFileSync(new URL(rel, import.meta.url), "utf8");
const stripComments = (src) => src.replace(/^[ \t]*\/\/.*$/gm, "");

const ACTIONS = stripComments(read("./actions.ts"));
const DEFAULT_RELATIONSHIP = stripComments(read("../../../../lib/factoring/default-relationship.ts"));
const CLIENT = stripComments(read("./factoring-settings-client.tsx"));
const INVOICE_PAGE = stripComments(read("../../invoices/[id]/page.tsx"));
const FACTORING_ACTIONS = stripComments(read("../../invoices/factoring-actions.ts"));
const FACTORING_SECTION = stripComments(read("../../../../components/invoices/factoring-section.tsx"));

// ==========================================================================
// H.1/H.3: carrier required when creating a factoring relationship;
// inactive carrier rejected for a new relationship.
// ==========================================================================
test("H.1/H.3: createFactoringRelationship requires a carrierId and validates it before insert", () => {
  assert.match(ACTIONS, /export async function createFactoringRelationship\(carrierId: string, companyId: string, formData: FormData\)/);
  assert.match(ACTIONS, /const carrierCheck = await validateCarrierForNewRelationship\(carrierId, auth\.organizationId\)/);
  assert.match(ACTIONS, /if \(!carrierCheck\.ok\) return carrierCheck;/);
  // the insert itself always carries carrier_id -- never optional/omitted
  assert.match(ACTIONS, /\.insert\(\{ \.\.\.parsed\.values, organization_id: auth\.organizationId, factoring_company_id: companyId, carrier_id: carrierId \}\)/);
});

test("H.3: an inactive carrier gets its own distinct rejection message, not a generic 'not found'", () => {
  assert.match(ACTIONS, /if \(!carrier\.is_active\) return \{ ok: false, error: "That carrier is inactive and cannot be used for a new factoring relationship\." \};/);
});

// ==========================================================================
// H.2: cross-organization carrier rejected -- the validation query is
// scoped to the caller's own organization, never a client-supplied one.
// ==========================================================================
test("H.2: carrier validation is scoped to the caller's own organizationId, never a client-supplied value", () => {
  assert.match(ACTIONS, /\.from\("carriers"\)\.select\("id, is_active"\)\.eq\("id", carrierId\)\.eq\("organization_id", organizationId\)/);
  // organizationId passed into validateCarrierForNewRelationship always
  // comes from auth.organizationId (requireFactoringAccess's own
  // getCurrentOrgId() derivation), never a form field or argument.
  assert.match(ACTIONS, /validateCarrierForNewRelationship\(carrierId, auth\.organizationId\)/);
  assert.equal(/validateCarrierForNewRelationship\([^,]+,\s*formData/.test(ACTIONS), false, "must never derive organizationId from form input");
});

// ==========================================================================
// H.4: an existing relationship's carrier can never be changed through
// this app -- updateFactoringRelationship's value set has no carrier_id
// path anywhere, and relationshipValuesFromForm never reads one.
// ==========================================================================
test("H.4: updateFactoringRelationship never writes carrier_id (immutable after creation)", () => {
  const fnMatch = ACTIONS.match(/export async function updateFactoringRelationship\(relationshipId: string, formData: FormData\)[\s\S]*?\n}/);
  assert.ok(fnMatch, "updateFactoringRelationship not found");
  assert.equal(fnMatch[0].includes("carrier_id"), false, "updateFactoringRelationship must never reference carrier_id");
  // relationshipValuesFromForm (shared by create AND update) never reads a
  // carrier_id form field either -- the ONLY carrier_id in an insert comes
  // from createFactoringRelationship's own explicit, validated parameter.
  const valuesFnMatch = ACTIONS.match(/function relationshipValuesFromForm\(formData: FormData\)[\s\S]*?\n}/);
  assert.ok(valuesFnMatch, "relationshipValuesFromForm not found");
  assert.equal(valuesFnMatch[0].includes("carrier_id"), false);
});

test("H.4 (UI): editing an existing relationship renders the carrier as a locked label, never an editable control", () => {
  assert.match(CLIENT, /Carrier\s*\n\s*<div className="flex h-8 items-center justify-between rounded-md border border-border bg-muted\/40 px-2 text-sm text-foreground">/);
  assert.match(CLIENT, /Locked<\/span>/);
  // the create-mode branch is a <select>; the edit-mode branch renders a
  // plain, non-form-field <div> label -- no `name="carrier_id"` input
  // exists anywhere in this file, so a submitted edit form cannot smuggle
  // one in even if a caller tried.
  assert.equal(CLIENT.includes('name="carrier_id"'), false, "no form field can submit a carrier_id from this UI");
});

// ==========================================================================
// H.13: secret_reference never reaches an application response or
// rendered component -- neither the default-relationship lookup nor the
// settings UI ever selects, returns, or displays it.
// ==========================================================================
test("H.13: no application file in the factoring settings/lookup path references secret_reference", () => {
  for (const [name, src] of [
    ["default-relationship.ts", DEFAULT_RELATIONSHIP],
    ["factoring-settings-client.tsx", CLIENT],
    ["settings/factoring/actions.ts", ACTIONS],
  ]) {
    assert.equal(src.includes("secret_reference"), false, `${name} must never reference secret_reference`);
  }
});

// ==========================================================================
// H.14/H.15: unauthorized roles cannot perform protected factoring
// mutations; no ordinary user mutation depends on service_role.
// ==========================================================================
test("H.14: setCarrierFactoringPolicy requires the STRICTER owner/admin gate, not the FINANCIAL_ROLES gate the other actions use", () => {
  assert.match(ACTIONS, /async function requireOwnerAdminFactoringAccess\(\)/);
  assert.match(ACTIONS, /if \(!OWNER_ADMIN_ROLES\.includes\(auth\.role\)\)/);
  const policyFnMatch = ACTIONS.match(/export async function setCarrierFactoringPolicy\([\s\S]*?\n}/);
  assert.ok(policyFnMatch, "setCarrierFactoringPolicy not found");
  assert.match(policyFnMatch[0], /requireOwnerAdminFactoringAccess\(\)/);
});

// Phase 3B.1.4 (Section A): the authorization matrix tightened from the
// original Phase 2H.3 "every FINANCIAL_ROLES member may do everything
// here" design. This replaces the Phase 3B.1.3 version of this same test,
// which asserted that now-undesired, now-closed behavior.
function fnBody(name) {
  const re = new RegExp(`export async function ${name}\\([^)]*\\)[\\s\\S]*?\\n}`);
  const m = ACTIONS.match(re);
  assert.ok(m, `${name} not found`);
  return m[0];
}

test("I.4: owner/admin-only mutations (create/delete company, change company identity, create relationship, set default) use requireOwnerAdminFactoringAccess", () => {
  for (const fn of ["createFactoringCompany", "updateFactoringCompany", "setFactoringCompanyActive", "deleteFactoringCompany", "createFactoringRelationship", "setDefaultFactoringRelationship"]) {
    assert.match(fnBody(fn), /requireOwnerAdminFactoringAccess\(\)/, `${fn} must use requireOwnerAdminFactoringAccess`);
  }
});

test("I.5: owner/admin/accountant edit access (ordinary relationship terms + is_active) uses requireFactoringEditAccess, dispatcher excluded", () => {
  assert.match(ACTIONS, /const EDIT_ROLES: OrgRole\[\] = \["owner", "admin", "accountant"\];/);
  for (const fn of ["updateFactoringRelationship", "setFactoringRelationshipActive"]) {
    assert.match(fnBody(fn), /requireFactoringEditAccess\(\)/, `${fn} must use requireFactoringEditAccess`);
  }
});

test("I.1/I.2/I.3: no factoring mutation function uses the old, now-too-broad requireFactoringAccess() as its OWN gate", () => {
  for (const fn of ["createFactoringCompany", "updateFactoringCompany", "setFactoringCompanyActive", "deleteFactoringCompany", "createFactoringRelationship", "updateFactoringRelationship", "setDefaultFactoringRelationship", "setFactoringRelationshipActive", "setCarrierFactoringPolicy"]) {
    const body = fnBody(fn);
    // requireFactoringAccess() is called INSIDE the two stricter helpers
    // themselves, never directly by name from a mutation's own first line.
    assert.equal(/const auth = await requireFactoringAccess\(\);/.test(body), false, `${fn} must not use the bare read-only gate for a mutation`);
  }
});

test("H.15: settings/factoring/actions.ts contains no service_role usage anywhere", () => {
  assert.equal(ACTIONS.includes("service-role"), false);
  assert.equal(ACTIONS.includes("createServiceRoleClient"), false);
  assert.equal(ACTIONS.includes("service_role"), false);
  // every mutation goes through the caller's own session client
  assert.match(ACTIONS, /import \{ createClient \} from "@\/lib\/supabase\/server";/);
});

// ==========================================================================
// H.5/H.6/H.7: getDefaultFactoringRelationship's contract -- carrier
// -scoped, never falls back to another carrier, detects multiple defaults
// as an integrity error rather than returning an arbitrary row.
// ==========================================================================
test("H.5/H.6: getDefaultFactoringRelationship requires carrierId and filters strictly by it (never organization-wide)", () => {
  assert.match(DEFAULT_RELATIONSHIP, /export async function getDefaultFactoringRelationship\(carrierId: string\)/);
  assert.match(DEFAULT_RELATIONSHIP, /if \(!carrierId\) \{\s*throw new Error/);
  assert.match(DEFAULT_RELATIONSHIP, /\.eq\("carrier_id", carrierId\)/);
  // the old organization-wide signature must be gone entirely
  assert.equal(/getDefaultFactoringRelationship\(organizationId/.test(DEFAULT_RELATIONSHIP), false, "no organization-wide lookup path may remain");
});

test("H.7: 2+ active defaults for the same carrier is reported as an integrity_error, never an arbitrary pick", () => {
  assert.match(DEFAULT_RELATIONSHIP, /relationships\.length > 1/);
  assert.match(DEFAULT_RELATIONSHIP, /status: "integrity_error"/);
  // The default-relationship SELECT itself (carrier_id + is_default +
  // is_active) must not chain .maybeSingle()/.single() -- either would
  // silently error out or truncate to one row before the length>1 check
  // above ever runs. Isolate that one query (up to its own semicolon) and
  // assert directly on it, rather than searching the whole file (which
  // also contains an unrelated, legitimate .maybeSingle() call further
  // down, for the factoring_companies lookup).
  const queryMatch = DEFAULT_RELATIONSHIP.match(/\.from\("factoring_relationships"\)[\s\S]*?\.eq\("is_active", true\);/);
  assert.ok(queryMatch, "default-relationship query not found");
  assert.equal(queryMatch[0].includes(".maybeSingle()"), false);
  assert.equal(queryMatch[0].includes(".single()"), false);
});

// ==========================================================================
// Phase 3B.1.5 (Section A) -- CORRECTION of the H.16/H.11/H.10/H.6/I.7/I.11/
// I.10/I.14 tests that used to live here. 3B.1.4's carrierGate treated a
// carrier LIVE-derived from the invoice's dispatch/load record as
// sufficient to authorize a factoring submission -- but that live
// association is not an immutable financial snapshot and can change at
// any time with no trace on the invoice, so it must never again decide
// eligibility. The invoice page no longer derives a carrier, no longer
// calls getDefaultFactoringRelationship, and no longer ever offers a
// relationship -- eligibility is unconditionally false (once past the
// status/resubmission pre-checks) with the exact snapshot-required
// wording submit_invoice_to_factor() (0140) itself returns.
// ==========================================================================
test("3B.1.5: the invoice page no longer derives a carrier from dispatch/load, and never calls getDefaultFactoringRelationship", () => {
  assert.equal(/invoiceCarrierId/.test(INVOICE_PAGE), false, "no live carrier derivation may remain on the invoice page");
  assert.equal(/getDefaultFactoringRelationship/.test(INVOICE_PAGE), false, "the legacy invoice page must not call getDefaultFactoringRelationship any more");
  assert.equal(INVOICE_PAGE.includes('import { getDefaultFactoringRelationship }'), false);
});

test("3B.1.6 (Section F): the invoice page never constructs a 'ready' FactoringSectionEligibility -- no artificial empty relationshipOptions/defaultRelationshipId constants, no carrierGate branch", () => {
  // 3B.1.5's own "permanently empty constants" approach is gone -- there
  // is no relationshipOptions/defaultRelationshipId local at all any more
  // on this page; the discriminated union's "blocked" variant simply
  // carries no such field.
  assert.equal(/relationshipOptions/.test(INVOICE_PAGE), false, "the invoice page must not declare/thread a relationshipOptions value at all");
  assert.equal(/defaultRelationshipId/.test(INVOICE_PAGE), false, "the invoice page must not declare/thread a defaultRelationshipId value at all");
  assert.equal(/carrierGate/.test(INVOICE_PAGE), false, "the old carrier-derivation gate must be gone entirely");
  assert.equal(/status:\s*"ready"/.test(INVOICE_PAGE), false, "the legacy invoice page must never construct the 'ready' eligibility variant");
  assert.match(INVOICE_PAGE, /const factoringEligibility: FactoringSectionEligibility =/);
});

test("3B.1.6: eligibility is unconditionally 'blocked' (once status-eligible and resubmittable) with the exact snapshot-required wording, matching 0140's own message", () => {
  const EXACT = "This invoice was created before carrier-specific financial snapshots were enabled. Review and reissue it through the new invoice workflow.";
  assert.ok(INVOICE_PAGE.includes(EXACT), "invoice page must use the exact snapshot-required message");
  const MIGRATION_0140 = stripComments(read("../../../../../supabase/migrations/0140_factoring_authorization_and_submission_safety.sql"));
  assert.ok(MIGRATION_0140.includes(EXACT), "submit_invoice_to_factor() (0140) must raise the identical wording -- the UI gate and the DB rejection must never drift apart");
  assert.match(INVOICE_PAGE, /const factoringEligibility: FactoringSectionEligibility = !statusEligibility\.eligible/);
  assert.match(INVOICE_PAGE, /\{ status: "blocked", reason: SNAPSHOT_REQUIRED_REASON \}/);
});

test("3B.1.6: FactoringSection's 'blocked' variant carries no relationship field, and the Submit dialog is only reachable from 'ready'", () => {
  assert.match(FACTORING_SECTION, /\{ status: "blocked"; reason: string \}/);
  assert.match(FACTORING_SECTION, /\{ status: "ready"; relationshipOptions: RelationshipOption\[\]; defaultRelationshipId: string \| null \}/);
  assert.match(FACTORING_SECTION, /const canShowSubmitButton = eligibility\.status === "ready" && eligibility\.relationshipOptions\.length > 0 && canResubmit;/);
  assert.match(FACTORING_SECTION, /\{submitOpen && eligibility\.status === "ready" && \(/);
});

// ==========================================================================
// I.13 (extended): secret_reference must never reach the invoice
// submission path either -- not just the settings page.
// ==========================================================================
test("I.13: the invoice submission path (page, factoring-actions, factoring-section) never references secret_reference", () => {
  for (const [name, src] of [
    ["invoices/[id]/page.tsx", INVOICE_PAGE],
    ["invoices/factoring-actions.ts", FACTORING_ACTIONS],
    ["components/invoices/factoring-section.tsx", FACTORING_SECTION],
  ]) {
    assert.equal(src.includes("secret_reference"), false, `${name} must never reference secret_reference`);
  }
});

// ==========================================================================
// I.18 (extended): the invoice submission action file also uses the
// caller's own session, never service_role.
// ==========================================================================
test("I.18: invoices/factoring-actions.ts contains no service_role usage anywhere", () => {
  assert.equal(FACTORING_ACTIONS.includes("service-role"), false);
  assert.equal(FACTORING_ACTIONS.includes("createServiceRoleClient"), false);
  assert.equal(FACTORING_ACTIONS.includes("service_role"), false);
});

// ==========================================================================
// H (Section H): carrier name and the selected factor are shown before
// confirmation.
// ==========================================================================
test("H: SubmitToFactorDialog renders the carrier name before confirmation", () => {
  const dialogMatch = FACTORING_SECTION.match(/function SubmitToFactorDialog\([\s\S]*?\n}\n/);
  assert.ok(dialogMatch, "SubmitToFactorDialog not found");
  assert.match(dialogMatch[0], /selected\.carrierName/);
});

// ==========================================================================
// Phase 3B.1.5 (Section B/G): submit_invoice_to_factor() (0140) now
// returns jsonb, not table(factored_invoice_id, status) -- the action
// must decide success/failure via resolveStructuredRpcResult() (never by
// checking `error` alone, and never by assuming `data` is a row array),
// and the button/dialog that would call it stays inert because the
// legacy invoice page only ever constructs the "blocked" eligibility
// variant, which carries no relationship data at all (asserted above).
// ==========================================================================
test("3B.1.5: submitInvoiceToFactor resolves success via resolveStructuredRpcResult, never by checking `error` alone", () => {
  assert.match(FACTORING_ACTIONS, /import \{ resolveStructuredRpcResult, type StructuredRpcResult \} from "@\/lib\/factoring\/rpc-result";/);
  assert.match(FACTORING_ACTIONS, /const resolved = resolveStructuredRpcResult<SubmitInvoiceToFactorRpcResult>\(rpcResult, error\);/);
  assert.match(FACTORING_ACTIONS, /if \(!resolved\.ok\) \{/);
  // the old table(...)-shaped access pattern must be gone
  assert.equal(/Array\.isArray\(data\)/.test(FACTORING_ACTIONS), false, "must no longer treat the RPC result as a row array");
});

test("3B.1.5: a resolved rejection surfaces the RPC's own code/snapshot_required, never a hardcoded assumption", () => {
  assert.match(FACTORING_ACTIONS, /code: rpcResult\?\.code,/);
  assert.match(FACTORING_ACTIONS, /snapshotRequired: rpcResult\?\.snapshot_required === true,/);
});
