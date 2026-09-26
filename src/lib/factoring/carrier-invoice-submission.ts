// Proposal 0157 (F-08, carrier invoices) -- framework-independent logic for the "Submit to factoring" path. NO Supabase / Next imports so it can be unit-tested
// directly under `node --test` (same reason as rpc-result.ts). The database is the only authority: everything here is presentation. Nothing in this module chooses a
// factor, a relationship or a carrier; the RPCs return the server-resolved destination and the client can only confirm it.

export type FactoringPreview = {
  success?: boolean;
  eligible?: boolean;
  code?: string;
  message?: string;
  carrier_id?: string;
  carrier_name?: string;
  invoice_number?: string;
  currency?: string;
  invoice_total?: number | string;
  factoring_company_name?: string;
  relationship_name?: string | null;
  advance_percentage?: number | string;
  factoring_fee_percentage?: number | string;
  reserve_percentage?: number | string;
  fee_timing?: string;
  expected_advance_amount?: number | string;
  factoring_fee_amount?: number | string;
  reserve_amount?: number | string;
  expected_funding_amount?: number | string;
  submission_method?: string | null;
  submission_destination?: string | null;
  noa_reference?: string | null;
  reissue_required?: boolean;
  drift_dimensions?: string[];
  [key: string]: unknown;
};

export type FactoringSubmitResult = {
  success?: boolean;
  code?: string;
  message?: string;
  submission_id?: string;
  status?: string;
  idempotent_replay?: boolean;
  [key: string]: unknown;
};

// Every stable machine code the 0157 RPCs can return, with a fixed safe fallback sentence (the RPC's own message is preferred whenever present; this table only guarantees
// the UI can never show "undefined" or a raw database error).
export const FACTORING_CODE_MESSAGES: Record<string, string> = {
  FORBIDDEN: "You are not permitted to submit invoices for factoring.",
  NOT_FOUND: "Carrier invoice not found.",
  NOT_AUTHORIZED_FOR_CARRIER: "You are not authorized to submit invoices of this carrier for factoring.",
  INVALID_REQUEST: "The request was incomplete. Please refresh the page and try again.",
  IDEMPOTENCY_KEY_REUSED: "This request was already used for a different invoice. Please refresh the page and try again.",
  FEATURE_DISABLED: "Factoring submission for carrier invoices is not enabled.",
  WRONG_DOCUMENT_TYPE: "Only carrier freight invoices can be factored; dispatch-service invoices are a separate receivable.",
  INVOICE_VOIDED: "A voided invoice cannot be factored.",
  INVOICE_NOT_ISSUED: "Only an issued invoice can be factored.",
  INVOICE_PAID_OR_PARTIAL: "A paid or partially paid invoice cannot be factored.",
  INVOICE_AMOUNT_INVALID: "The invoice total must be greater than zero.",
  DISPATCH_FEE_ON_INVOICE: "This invoice contains a dispatch-service fee line; dispatch fees are a separate receivable and cannot be factored.",
  SNAPSHOT_MISSING: "This invoice has no single issuance snapshot and cannot be factored.",
  SNAPSHOT_MISMATCH: "The invoice no longer matches its issuance snapshot; it cannot be factored.",
  ISSUED_AS_DIRECT_BILLING: "This invoice was issued for direct billing and cannot be factored; it must be correctly reissued.",
  RELATIONSHIP_DRIFT_REISSUE_REQUIRED: "The carrier's factoring relationship, factor, NOA, recipient, routing or terms changed since this invoice was issued. It cannot be submitted; it must be reissued.",
  ISSUANCE_RECORD_MISSING_REISSUE_REQUIRED: "This invoice was not issued through the controlled issuance workflow; it must be reissued before it can be factored.",
  CARRIER_INACTIVE: "The carrier is missing, inactive or belongs to another organization.",
  DIRECT_BILLING: "This carrier is configured for direct billing or is unconfigured; it cannot use factoring.",
  NOT_FACTORING_ELIGIBLE: "This carrier/recipient is not factoring-eligible or is approved for direct billing.",
  NOT_READY: "This carrier is not ready to factor this invoice.",
  NO_ACTIVE_DEFAULT_RELATIONSHIP: "This carrier has no active default factoring relationship.",
  MULTIPLE_DEFAULT_RELATIONSHIPS: "This carrier has more than one active default factoring relationship; an owner or admin must fix the configuration.",
  RELATIONSHIP_NOT_EFFECTIVE: "The carrier's factoring relationship is not currently effective.",
  COMPANY_INACTIVE: "The factoring company is inactive.",
  UNRESOLVED_LEGACY_RECORD: "An unresolved legacy record exists for this invoice or factoring relationship; an owner or admin must resolve it first.",
  NEGATIVE_FUNDING: "Estimated funding for this invoice would be negative under the carrier's factoring terms.",
  ALREADY_SUBMITTED: "This invoice has already been submitted to a factor.",
};

export const GENERIC_FAILURE = "The factoring request could not be completed. Please refresh the page and try again.";

export function messageForResult(result: { code?: string; message?: string } | null | undefined): string {
  if (!result) return GENERIC_FAILURE;
  if (typeof result.message === "string" && result.message.trim()) return result.message;
  if (result.code && FACTORING_CODE_MESSAGES[result.code]) return FACTORING_CODE_MESSAGES[result.code];
  return GENERIC_FAILURE;
}

/** The submit control is offered ONLY when the server-side preview says the invoice is eligible. Hiding it is a convenience: the RPC re-checks everything. */
export function canOfferSubmit(preview: FactoringPreview | null | undefined): boolean {
  return !!preview && preview.success === true && preview.eligible === true;
}

/** Refusals that are cured ONLY by the controlled reissue workflow (D-57c / D-57d): the panel directs the user there instead of offering any submit control. */
export const REISSUE_CODES: ReadonlySet<string> = new Set(["RELATIONSHIP_DRIFT_REISSUE_REQUIRED", "ISSUED_AS_DIRECT_BILLING", "ISSUANCE_RECORD_MISSING_REISSUE_REQUIRED"]);

export type PanelState =
  | { kind: "hidden" }
  | { kind: "blocked"; code: string; message: string }
  | { kind: "reissue_required"; code: string; message: string; dimensions: string[] }
  | { kind: "ready"; preview: FactoringPreview };

/** Presentation state for the panel. A disabled feature or a document that can never be factored renders nothing; every other refusal is shown with the RPC's own code and message. */
export function panelStateFor(preview: FactoringPreview | null | undefined): PanelState {
  if (!preview) return { kind: "hidden" };
  if (canOfferSubmit(preview)) return { kind: "ready", preview };
  const code = String(preview.code ?? "");
  if (code === "FEATURE_DISABLED" || code === "FORBIDDEN" || code === "NOT_FOUND" || code === "WRONG_DOCUMENT_TYPE" || code === "NOT_AUTHORIZED_FOR_CARRIER") return { kind: "hidden" };
  if (REISSUE_CODES.has(code)) return { kind: "reissue_required", code, message: messageForResult(preview), dimensions: Array.isArray(preview.drift_dimensions) ? preview.drift_dimensions.map(String) : [] };
  return { kind: "blocked", code, message: messageForResult(preview) };
}

/** One key per confirmation dialog opening: retries and double clicks inside one confirmation reuse it, so the database replays instead of submitting twice. */
export function newIdempotencyKey(random: () => string = () => globalThis.crypto.randomUUID()): string {
  return `cif-${random()}`;
}

export function isValidIdempotencyKey(key: unknown): key is string {
  return typeof key === "string" && /^cif-[0-9a-fA-F-]{8,64}$/.test(key);
}

/** In-flight guard: returns false (and does nothing) if a submission is already running; otherwise marks it running. Pure state object so it is testable. */
export function tryBeginSubmit(state: { inFlight: boolean }): boolean {
  if (state.inFlight) return false;
  state.inFlight = true;
  return true;
}

export type SubmitOutcome = { ok: true; submissionId: string; status: string; replay: boolean } | { ok: false; code: string; error: string };

export function outcomeFromRpc(data: FactoringSubmitResult | null | undefined, error: { message: string } | null | undefined): SubmitOutcome {
  if (error) return { ok: false, code: "TRANSPORT", error: GENERIC_FAILURE };   // a raw Postgres/PostgREST message is never shown
  if (!data || data.success !== true || !data.submission_id || !data.status) return { ok: false, code: String(data?.code ?? "UNKNOWN"), error: messageForResult(data) };
  return { ok: true, submissionId: String(data.submission_id), status: String(data.status), replay: data.idempotent_replay === true };
}

const money = (v: number | string | undefined, cur = "USD") => (v === undefined ? "--" : `${cur} ${Number(v).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);

/** The confirmation lines shown to the user: the server-resolved destination and terms, read-only. There is no picker and no editable field. */
export function confirmationLines(p: FactoringPreview): Array<{ label: string; value: string }> {
  const cur = p.currency ?? "USD";
  return [
    { label: "Carrier", value: String(p.carrier_name ?? "--") },
    { label: "Invoice", value: `${p.invoice_number ?? "--"} (${money(p.invoice_total, cur)})` },
    { label: "Factoring company (server-selected)", value: String(p.factoring_company_name ?? "--") },
    { label: "Relationship (carrier's active default)", value: String(p.relationship_name ?? "--") },
    { label: "Submission route", value: `${p.submission_method ?? "--"}${p.submission_destination ? ` -> ${p.submission_destination}` : ""}` },
    { label: "NOA reference", value: String(p.noa_reference ?? "--") },
    { label: "Advance / fee / reserve", value: `${p.advance_percentage ?? "--"}% / ${p.factoring_fee_percentage ?? "--"}% / ${p.reserve_percentage ?? "--"}%` },
    { label: "Expected advance / fee / reserve", value: `${money(p.expected_advance_amount, cur)} / ${money(p.factoring_fee_amount, cur)} / ${money(p.reserve_amount, cur)}` },
    { label: "Expected funding", value: money(p.expected_funding_amount, cur) },
  ];
}
