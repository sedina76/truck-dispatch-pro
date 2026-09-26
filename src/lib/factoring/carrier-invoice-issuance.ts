// Proposal 0157 (D-57) -- framework-independent logic for the carrier-invoice ISSUANCE / REISSUE workflow. NO Supabase / Next imports so it is unit-testable under `node --test`.
// The database is the only authority: everything here is presentation. Nothing in this module chooses a relationship, factor, recipient routing, organization or total; the RPCs
// resolve those server-side and the client can only confirm what the server previewed.

export type IssuanceLoad = { load_id: string; load_number: string; amount: number | string };

export type IssuanceFactoring = {
  factoring_company_name?: string;
  relationship_name?: string | null;
  advance_percentage?: number | string;
  factoring_fee_percentage?: number | string;
  reserve_percentage?: number | string;
  fee_timing?: string;
  other_fee_amount?: number | string;
  expected_advance_amount?: number | string;
  factoring_fee_amount?: number | string;
  reserve_amount?: number | string;
  expected_funding_amount?: number | string;
  noa_reference?: string | null;
  submission_method?: string | null;
  remittance_instructions?: string | null;
};

export type DispatchFeePreview = { status: "agreement_effective" | "no_effective_agreement" | "currency_mismatch"; estimated_total?: number | string | null; fee_method?: string; currency?: string };

export type IssuancePreview = {
  success?: boolean;
  eligible?: boolean;
  code?: string;
  message?: string;
  carrier_id?: string;
  carrier_name?: string;
  billing_mode?: "factored" | "direct_billing";
  recipient_type?: "broker" | "customer";
  recipient_id?: string;
  recipient_name?: string;
  currency?: string;
  loads?: IssuanceLoad[];
  load_count?: number;
  freight_total?: number | string;
  factoring?: IssuanceFactoring | null;
  dispatch_fee?: DispatchFeePreview;
  old_invoice_number?: string;
  old_total?: number | string;
  drift_dimensions?: string[];
  reissue_needed?: boolean;
  [key: string]: unknown;
};

export type WorkflowResult = {
  success?: boolean;
  code?: string;
  message?: string;
  invoice_id?: string;
  invoice_number?: string;
  status?: string;
  updated_at?: string;
  replacement_invoice_id?: string;
  original_invoice_id?: string;
  billing_mode?: string;
  idempotent_replay?: boolean;
  dispatch_fee?: { status?: string; dispatch_invoice_id?: string };
  discarded?: boolean;
  [key: string]: unknown;
};

// Every stable machine code the issuance/reissue RPCs (and the 0144/0145 issue_carrier_invoice they wrap) can return, with a fixed safe sentence. The RPC's own message is preferred; this table only
// guarantees the UI can never show "undefined" or a raw database error.
export const ISSUANCE_CODE_MESSAGES: Record<string, string> = {
  FORBIDDEN: "You are not permitted to perform this action.",
  INVALID_REQUEST: "The request was incomplete. Please refresh the page and try again.",
  NOT_FOUND: "Carrier invoice not found.",
  NOT_AUTHORIZED_FOR_CARRIER: "You are not authorized to invoice this carrier.",
  IDEMPOTENCY_KEY_REUSED: "This request was already used for something else. Please refresh the page and try again.",
  CARRIER_NOT_FOUND: "The carrier was not found.",
  CARRIER_INACTIVE: "The carrier is inactive.",
  CARRIER_INVOICE_CODE_MISSING: "The carrier has no invoice code; set one before invoicing.",
  FACTORING_POLICY_UNCONFIGURED: "This carrier has no billing policy configured (direct or factored).",
  RECIPIENT_NOT_FOUND: "The broker or customer was not found.",
  LOAD_SELECTION_INVALID: "Select between 1 and 200 distinct loads.",
  LOAD_NOT_FOUND: "One or more selected loads were not found.",
  LOAD_CARRIER_MISMATCH: "Every selected load must belong to the selected carrier.",
  LOAD_RECIPIENT_MISMATCH: "Every selected load must belong to the selected broker or customer.",
  LOAD_NOT_BILLABLE: "Only delivered loads can be invoiced.",
  LOAD_AMOUNT_INVALID: "Every selected load needs a freight amount greater than zero.",
  LOAD_ALREADY_INVOICED: "One or more selected loads are already on another live carrier invoice.",
  UNRESOLVED_LEGACY_RECORD: "An unresolved legacy record exists for this carrier's factoring relationship; an owner or admin must resolve it first.",
  NO_ACTIVE_DEFAULT_RELATIONSHIP: "This carrier has no active default factoring relationship.",
  MULTIPLE_DEFAULT_RELATIONSHIPS: "This carrier has more than one active default factoring relationship; an owner or admin must fix the configuration.",
  RELATIONSHIP_NOT_EFFECTIVE: "The carrier's factoring relationship is not currently effective.",
  COMPANY_INACTIVE: "The factoring company is inactive.",
  NOT_READY: "This carrier is not ready to factor invoices to this recipient.",
  WRONG_DOCUMENT_TYPE: "Only carrier freight invoices use this workflow.",
  INVOICE_NOT_DRAFT: "Only a draft can be changed here; use reissue for an issued invoice.",
  INVOICE_NOT_READY: "Only an invoice marked ready for issue can be issued.",
  STALE_INVOICE: "The invoice changed since you loaded it. Reload and try again.",
  NOT_A_WORKFLOW_DRAFT: "This draft was not created through the controlled issuance workflow.",
  DRAFT_LOADS_CHANGED: "The draft's loads no longer match its billable-record ledger.",
  INVOICE_TOTAL_MISMATCH: "The invoice total no longer matches its loads.",
  STALE_CONFIGURATION: "The carrier's billing configuration changed while processing. Please retry.",
  INVOICE_VOIDED: "A voided invoice cannot be reissued.",
  INVOICE_NOT_ISSUED: "Only an issued invoice can be reissued.",
  INVOICE_PAID_OR_PARTIAL: "A paid or partially paid invoice cannot be reissued automatically.",
  SUBMISSION_EXISTS: "This invoice has a factoring submission and cannot be reissued.",
  ALREADY_REISSUED: "This invoice was already reissued.",
  REISSUE_TOTAL_CHANGED: "The loads' current freight total differs from this invoice; a reissue never changes amounts.",
  // passthrough codes of the existing issuance function (0144/0145) that the wrapper relays unchanged
  INVOICE_INCOMPLETE: "The invoice is incomplete (for example a load is missing a pickup or delivery stop).",
  FACTORING_NOT_READY: "This carrier's factoring configuration is not ready for issuance.",
  INVALID_INPUT: "The request was incomplete. Please refresh the page and try again.",
};

export const ISSUANCE_GENERIC_FAILURE = "The request could not be completed. Please refresh the page and try again.";

export function issuanceMessage(result: { code?: string; message?: string } | null | undefined): string {
  if (!result) return ISSUANCE_GENERIC_FAILURE;
  if (typeof result.message === "string" && result.message.trim()) return result.message;
  if (result.code && ISSUANCE_CODE_MESSAGES[result.code]) return ISSUANCE_CODE_MESSAGES[result.code];
  return ISSUANCE_GENERIC_FAILURE;
}

/** One key per confirmation: retries and double clicks inside one confirmation reuse it, so the database replays instead of acting twice. Same format the server actions validate. */
export function newWorkflowKey(random: () => string = () => globalThis.crypto.randomUUID()): string {
  return `cif-${random()}`;
}

export function isValidWorkflowKey(key: unknown): key is string {
  return typeof key === "string" && /^cif-[0-9a-fA-F-]{8,64}$/.test(key);
}

const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
export const isUuid = (v: unknown): v is string => typeof v === "string" && UUID.test(v);

export type IssuanceInput = { carrierId: string; loadIds: string[]; recipientType: "broker" | "customer"; recipientId: string };

/** Structural validation before any request (the database validates everything again). Returns an error code or null. */
export function validateIssuanceInput(i: Partial<IssuanceInput> | null | undefined): "INVALID_REQUEST" | "LOAD_SELECTION_INVALID" | null {
  if (!i || !isUuid(i.carrierId) || !isUuid(i.recipientId) || (i.recipientType !== "broker" && i.recipientType !== "customer")) return "INVALID_REQUEST";
  if (!Array.isArray(i.loadIds) || i.loadIds.length < 1 || i.loadIds.length > 200 || !i.loadIds.every(isUuid) || new Set(i.loadIds).size !== i.loadIds.length) return "LOAD_SELECTION_INVALID";
  return null;
}

export type Role = "owner" | "admin" | "dispatcher" | "accountant" | "driver" | "viewer" | string | null | undefined;
export const isCarrierInvoicePilotOperator = (role: Role): boolean => role === "owner" || role === "admin";

export type InvoiceLite = { issuance_status: string; payment_status: string; invoice_document_type: string };

/**
 * Which lifecycle controls the UI OFFERS. This is presentation only (hiding is not security): every RPC re-checks role, carrier grant and state. Preparing (draft / ready / discard) is offered to owner, admin
 * and dispatcher (a dispatcher without a carrier grant is refused by the database); ISSUING and REISSUING are offered to owner and admin only.
 */
export function lifecycleActions(invoice: InvoiceLite, role: Role, opts: { workflowDraft: boolean; hasSubmission: boolean }): { markReady: boolean; discard: boolean; issue: boolean; reissue: boolean; factoringPanel: boolean } {
  const freight = invoice.invoice_document_type === "carrier_freight_invoice";
  const prepares = role === "owner" || role === "admin" || role === "dispatcher";
  const ownerAdmin = isCarrierInvoicePilotOperator(role);
  const draft = freight && invoice.issuance_status === "draft" && opts.workflowDraft;
  const ready = freight && invoice.issuance_status === "ready_for_issue" && opts.workflowDraft;
  const issuedUnpaid = freight && invoice.issuance_status === "issued" && invoice.payment_status === "unpaid";
  return {
    markReady: draft && prepares,
    discard: (draft || ready) && prepares,
    issue: ready && ownerAdmin,
    reissue: issuedUnpaid && ownerAdmin && !opts.hasSubmission,
    // the factoring panel exists ONLY for a correctly ISSUED freight invoice (never for a draft / ready / voided invoice, never for a dispatch-service invoice)
    factoringPanel: ownerAdmin && freight && invoice.issuance_status === "issued",
  };
}

const money = (v: number | string | null | undefined, cur = "USD") => (v === undefined || v === null ? "--" : `${cur} ${Number(v).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);

export const DRIFT_LABELS: Record<string, string> = {
  relationship: "factoring relationship",
  factor: "factoring company",
  noa: "Notice of Assignment",
  recipient: "recipient",
  routing: "payment routing / submission route",
  terms: "advance, fee or reserve terms",
  billing_mode: "billing mode (direct vs factored)",
  issuance_record_missing: "no issuance record (issued outside the controlled workflow)",
};

export function driftSentence(dims: string[] | undefined): string {
  if (!dims || dims.length === 0) return "No change since issuance.";
  return `Changed since issuance: ${dims.map((d) => DRIFT_LABELS[d] ?? d).join(", ")}.`;
}

export function dispatchFeeLine(p: DispatchFeePreview | undefined): { label: string; value: string } {
  const label = "Dispatch-service fee (separate receivable; NOT part of this invoice or the factored amount)";
  if (!p) return { label, value: "--" };
  if (p.status === "agreement_effective") return { label, value: `${money(p.estimated_total, p.currency ?? "USD")} estimated -- billed separately to the carrier under its agreement` };
  if (p.status === "currency_mismatch") return { label, value: "Not billed: the agreement's currency differs from this invoice" };
  return { label, value: "Not billed: no approved, effective dispatch-service agreement for this carrier" };
}

/** The read-only lines the user confirms before a draft is created / an invoice is issued / reissued. There is no picker and no editable amount. */
export function issuanceConfirmationLines(p: IssuancePreview): Array<{ label: string; value: string }> {
  const cur = p.currency ?? "USD";
  const lines: Array<{ label: string; value: string }> = [
    { label: "Carrier", value: String(p.carrier_name ?? "--") },
    { label: p.recipient_type === "customer" ? "Customer (bill to)" : "Broker (bill to)", value: String(p.recipient_name ?? "--") },
    { label: "Billing mode (server-resolved)", value: p.billing_mode === "factored" ? "Factored" : p.billing_mode === "direct_billing" ? "Direct billing" : "--" },
    { label: "Loads", value: (p.loads ?? []).map((l) => `${l.load_number} (${money(l.amount, cur)})`).join(", ") || "--" },
    { label: "Freight total", value: money(p.freight_total, cur) },
  ];
  if (p.billing_mode === "factored" && p.factoring) {
    const f = p.factoring;
    lines.push(
      { label: "Factoring company (server-selected)", value: String(f.factoring_company_name ?? "--") },
      { label: "Relationship (carrier's active default)", value: String(f.relationship_name ?? "--") },
      { label: "Submission route", value: String(f.submission_method ?? "--") },
      { label: "NOA reference", value: String(f.noa_reference ?? "--") },
      { label: "Payment routing (remit to)", value: String(f.remittance_instructions ?? "--") },
      { label: "Advance / fee / reserve", value: `${f.advance_percentage ?? "--"}% / ${f.factoring_fee_percentage ?? "--"}% / ${f.reserve_percentage ?? "--"}%` },
      { label: "Expected advance / fee / reserve", value: `${money(f.expected_advance_amount, cur)} / ${money(f.factoring_fee_amount, cur)} / ${money(f.reserve_amount, cur)}` },
    );
  } else if (p.billing_mode === "direct_billing") {
    lines.push({ label: "Factoring", value: "None -- the carrier is billed directly; no factoring instructions are printed on this invoice" });
  }
  lines.push(dispatchFeeLine(p.dispatch_fee));
  return lines;
}

export type WorkflowOutcome = { ok: true; invoiceId: string; replacementInvoiceId?: string; status: string; replay: boolean; updatedAt?: string; dispatchFeeStatus?: string } | { ok: false; code: string; error: string };

export function outcomeFromWorkflow(data: WorkflowResult | null | undefined, error: { message: string } | null | undefined): WorkflowOutcome {
  if (error) return { ok: false, code: "TRANSPORT", error: ISSUANCE_GENERIC_FAILURE }; // a raw Postgres/PostgREST message is never shown
  if (!data || data.success !== true || !data.invoice_id || !data.status) return { ok: false, code: String(data?.code ?? "UNKNOWN"), error: issuanceMessage(data) };
  return {
    ok: true,
    invoiceId: String(data.invoice_id),
    replacementInvoiceId: data.replacement_invoice_id ? String(data.replacement_invoice_id) : undefined,
    status: String(data.status),
    replay: data.idempotent_replay === true,
    updatedAt: typeof data.updated_at === "string" ? data.updated_at : undefined,
    dispatchFeeStatus: data.dispatch_fee?.status,
  };
}

/** In-flight guard shared by every workflow button. */
export function tryBegin(state: { inFlight: boolean }): boolean {
  if (state.inFlight) return false;
  state.inFlight = true;
  return true;
}
