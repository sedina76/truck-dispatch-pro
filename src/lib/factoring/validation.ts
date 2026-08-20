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
