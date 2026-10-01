import type { FeeTiming, RecourseType } from "./types";

// Same email pattern used elsewhere in this app (settings/email/actions.ts)
// -- kept identical rather than inventing a second convention.
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
// Loose "looks like a domain/URL" check -- no protocol enforced (an org
// might type "rtsfinancial.com" or "https://rtsfinancial.com"), just
// rejects obvious garbage (no dot, contains whitespace).
const WEBSITE_RE = /^https?:\/\/.+\..+$|^[^\s]+\.[^\s]{2,}$/i;

export type FieldResult = { ok: true; value: string | null } | { ok: false; error: string };

export function validateOptionalEmail(label: string, raw: string | null): FieldResult {
  const trimmed = (raw ?? "").trim();
  if (!trimmed) return { ok: true, value: null };
  if (!EMAIL_RE.test(trimmed)) return { ok: false, error: `${label} must be a valid email address.` };
  return { ok: true, value: trimmed };
}

export function validateOptionalWebsite(label: string, raw: string | null): FieldResult {
  const trimmed = (raw ?? "").trim();
  if (!trimmed) return { ok: true, value: null };
  if (!WEBSITE_RE.test(trimmed)) return { ok: false, error: `${label} must be a valid website.` };
  return { ok: true, value: trimmed };
}

export type PercentResult = { ok: true; value: number } | { ok: false; error: string };

// Mirrors 0071's own `check (x >= 0 and x <= 100)` constraints exactly --
// this is a pre-check for a clean error message, never the real boundary.
export function validatePercent(label: string, raw: FormDataEntryValue | null): PercentResult {
  const str = String(raw ?? "").trim();
  if (str === "") return { ok: false, error: `${label} is required.` };
  const num = Number(str);
  if (Number.isNaN(num)) return { ok: false, error: `${label} must be a number.` };
  if (num < 0 || num > 100) return { ok: false, error: `${label} must be between 0 and 100.` };
  return { ok: true, value: num };
}

export type NonNegativeResult = { ok: true; value: number | null } | { ok: false; error: string };

// For the optional dollar-amount fee fields (minimum/wire/ach/other) --
// empty stays null (0071 allows null: "not specified" is a distinct,
// honest state from "$0", see the Phase 2H.2 review).
export function validateOptionalNonNegative(label: string, raw: FormDataEntryValue | null): NonNegativeResult {
  const str = String(raw ?? "").trim();
  if (str === "") return { ok: true, value: null };
  const num = Number(str);
  if (Number.isNaN(num)) return { ok: false, error: `${label} must be a number.` };
  if (num < 0) return { ok: false, error: `${label} cannot be negative.` };
  return { ok: true, value: num };
}

export function validateFeeTiming(raw: FormDataEntryValue | null): { ok: true; value: FeeTiming } | { ok: false; error: string } {
  const value = String(raw ?? "");
  if (value !== "deducted_at_funding" && value !== "deducted_from_reserve") {
    return { ok: false, error: "Fee timing must be either 'Deduct fee at funding' or 'Deduct fee from reserve'." };
  }
  return { ok: true, value };
}

export function validateRecourseType(raw: FormDataEntryValue | null): { ok: true; value: RecourseType } | { ok: false; error: string } {
  const value = String(raw ?? "");
  if (value !== "recourse" && value !== "non_recourse") {
    return { ok: false, error: "Recourse type must be either 'Recourse' or 'Non-recourse'." };
  }
  return { ok: true, value };
}

// Mirrors 0071's factoring_relationships_valid_effective_range constraint
// (effective_to is null or effective_from is null or effective_to >=
// effective_from) -- a pre-check for a clean message, not the real
// boundary.
export function validateEffectiveRange(effectiveFrom: string | null, effectiveTo: string | null): { ok: true } | { ok: false; error: string } {
  if (effectiveFrom && effectiveTo && effectiveTo < effectiveFrom) {
    return { ok: false, error: "Effective To date cannot be before Effective From date." };
  }
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Billing & Submission (remittance + submission method) form -- 0136's
// columns. Mirrors factoring_relationships_submission_email_present
// (secure_email needs a valid destination email) as a clean pre-check; the
// database CHECK and guard_factoring_relationship_protected_fields() (owner/
// admin only for remittance) remain the real boundary. "api" is never
// selectable here: it needs an active factoring API integration (0141) and
// is only ever kept as-is if a relationship already uses it.
// ---------------------------------------------------------------------------
const SELECTABLE_SUBMISSION_METHODS = ["secure_email", "portal_manual", "internal_queue"] as const;
const REMITTANCE_MAX = 2000;
const NOTES_MAX = 2000;

export type SubmissionSetupValues = {
  remittance_instructions: string | null;
  remittance_reference: string | null;
  submission_method: "secure_email" | "portal_manual" | "internal_queue" | "api" | null;
  submission_destination_email: string | null;
  submission_notes: string | null;
};

export function validateSubmissionSetup(
  input: {
    remittance_instructions: FormDataEntryValue | null;
    remittance_reference: FormDataEntryValue | null;
    submission_method: FormDataEntryValue | null;
    submission_destination_email: FormDataEntryValue | null;
    submission_notes: FormDataEntryValue | null;
  },
  currentMethod: string | null
): { ok: true; values: SubmissionSetupValues } | { ok: false; error: string } {
  const text = (v: FormDataEntryValue | null) => {
    const t = String(v ?? "").trim();
    return t === "" ? null : t;
  };
  const remittance = text(input.remittance_instructions);
  if (remittance && remittance.length > REMITTANCE_MAX) return { ok: false, error: `Remittance instructions must be ${REMITTANCE_MAX} characters or fewer.` };
  const notes = text(input.submission_notes);
  if (notes && notes.length > NOTES_MAX) return { ok: false, error: `Submission notes must be ${NOTES_MAX} characters or fewer.` };

  const rawMethod = text(input.submission_method);
  let method: SubmissionSetupValues["submission_method"] = null;
  if (rawMethod !== null) {
    if (rawMethod === "api") {
      if (currentMethod !== "api") return { ok: false, error: "API submission is set up through a factoring integration, not here." };
      method = "api";
    } else if ((SELECTABLE_SUBMISSION_METHODS as readonly string[]).includes(rawMethod)) {
      method = rawMethod as SubmissionSetupValues["submission_method"];
    } else {
      return { ok: false, error: "Choose a valid submission method." };
    }
  }

  let destinationEmail: string | null = null;
  if (method === "secure_email") {
    const email = text(input.submission_destination_email);
    if (!email) return { ok: false, error: "Enter the factor's submission email address." };
    if (!EMAIL_RE.test(email)) return { ok: false, error: "The submission email address is not valid." };
    destinationEmail = email;
  }

  return {
    ok: true,
    values: {
      remittance_instructions: remittance,
      remittance_reference: text(input.remittance_reference),
      submission_method: method,
      submission_destination_email: destinationEmail,
      submission_notes: notes,
    },
  };
}

// Approve-NOA form (approve_factoring_relationship_noa, 0140): reference and
// effective date are required, plus approved template language OR a
// verified NOA document. Same pre-check rules as the RPC itself.
export function validateNoaApproval(input: {
  noa_reference: FormDataEntryValue | null;
  noa_effective_date: FormDataEntryValue | null;
  noa_template_text: FormDataEntryValue | null;
  noa_document_id: FormDataEntryValue | null;
}): { ok: true; values: { reference: string; effectiveDate: string; templateText: string | null; documentId: string | null } } | { ok: false; error: string } {
  const reference = String(input.noa_reference ?? "").trim();
  if (!reference) return { ok: false, error: "Enter an NOA reference or version (for example \"ABC NOA v1\")." };
  const effectiveDate = String(input.noa_effective_date ?? "").trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(effectiveDate)) return { ok: false, error: "Enter the NOA's effective date." };
  const templateText = String(input.noa_template_text ?? "").trim() || null;
  const documentId = String(input.noa_document_id ?? "").trim() || null;
  if (!templateText && !documentId) return { ok: false, error: "Paste the approved NOA wording or choose a verified NOA document." };
  return { ok: true, values: { reference, effectiveDate, templateText, documentId } };
}
