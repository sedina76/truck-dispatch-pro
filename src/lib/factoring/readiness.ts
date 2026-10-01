// ---------------------------------------------------------------------------
// Factoring setup readiness checklist -- pure logic, no framework/database
// imports, unit-tested directly (readiness.test.mjs).
//
// A carrier can only be switched to "Factored" (set_carrier_factoring_policy,
// 0139) once it has ONE default relationship that is active, whose factoring
// company is active, whose effective dates cover today, and which has
// remittance instructions, an approved Notice of Assignment and a submission
// method. set_default_factoring_relationship (0138) itself refuses to make an
// incomplete relationship the default. This module mirrors exactly those
// database conditions so the UI can show WHAT is missing and IN WHAT ORDER to
// fix it -- the database remains the real boundary.
// ---------------------------------------------------------------------------

import type { FactoringSubmissionMethod } from "./types";

export type ReadinessRelationship = {
  is_default: boolean;
  is_active: boolean;
  effective_from: string | null;
  effective_to: string | null;
  remittance_instructions?: string | null;
  noa_approved?: boolean | null;
  submission_method?: FactoringSubmissionMethod | null;
};

export type ReadinessStepKey = "active" | "company_active" | "dates" | "remittance" | "submission_method" | "noa" | "default";

export type ReadinessStep = {
  key: ReadinessStepKey;
  label: string;
  done: boolean;
  /** Plain-language "how to fix" shown when not done. */
  fix: string;
  /** Short phrase for "still needs: ..." lists. */
  need: string;
};

// Steps in the order a user must complete them: Set Default refuses an
// incomplete relationship, and an inactive relationship cannot be the
// default, so "default" is always last.
export function relationshipReadinessSteps(
  rel: ReadinessRelationship,
  companyActive: boolean,
  today: string = new Date().toISOString().slice(0, 10)
): ReadinessStep[] {
  const datesOk = !(rel.effective_from && rel.effective_from > today) && !(rel.effective_to && rel.effective_to < today);
  const datesFix =
    rel.effective_from && rel.effective_from > today
      ? `It only starts on ${rel.effective_from}. Edit the relationship and set Effective From to today or earlier.`
      : `It ended on ${rel.effective_to}. Edit the relationship and clear or extend Effective To.`;

  return [
    { key: "active", label: "Relationship is active", done: rel.is_active, fix: "Click Reactivate on this relationship.", need: "to be reactivated" },
    { key: "company_active", label: "Factoring company is active", done: companyActive, fix: "Reactivate the factoring company in the Factoring Companies list.", need: "an active factoring company" },
    { key: "dates", label: "Effective dates cover today", done: datesOk, fix: datesFix, need: "effective dates that cover today" },
    {
      key: "remittance",
      label: "Remittance instructions",
      done: Boolean(rel.remittance_instructions && rel.remittance_instructions.trim()),
      fix: "Click Billing & Submission and enter where brokers must send payment.",
      need: "remittance instructions",
    },
    {
      key: "submission_method",
      label: "Submission method",
      done: Boolean(rel.submission_method),
      fix: "Click Billing & Submission and choose how invoices are sent to the factor.",
      need: "a submission method",
    },
    { key: "noa", label: "Notice of Assignment approved", done: Boolean(rel.noa_approved), fix: "Click Approve NOA.", need: "an approved Notice of Assignment" },
    { key: "default", label: "Set as this carrier's default", done: rel.is_default && rel.is_active, fix: "Click Set Default (available once every step above is done).", need: "to be set as the default" },
  ];
}

/** True when every step except "default" is done -- i.e. Set Default will succeed. */
export function canBecomeDefault(steps: ReadinessStep[]): boolean {
  return steps.filter((s) => s.key !== "default").every((s) => s.done);
}

/** True when the carrier could be switched to Factored on the strength of this relationship. */
export function isFullyReady(steps: ReadinessStep[]): boolean {
  return steps.every((s) => s.done);
}

/**
 * Builds the message shown when switching a carrier to Factored is refused.
 * Picks the relationship that is closest to ready (default first, then
 * active, then fewest missing steps) and lists what it still needs.
 */
export function notReadyMessage(
  carrierName: string,
  candidates: { name: string; steps: ReadinessStep[]; isDefault: boolean; isActive: boolean }[]
): string {
  if (candidates.length === 0) {
    return `${carrierName} has no factoring relationship yet. Open its factoring company under Factoring Companies, click Relationships, and add one for this carrier first.`;
  }
  const missingCount = (c: (typeof candidates)[number]) => c.steps.filter((s) => !s.done).length;
  const best = [...candidates].sort(
    (a, b) => Number(b.isDefault) - Number(a.isDefault) || Number(b.isActive) - Number(a.isActive) || missingCount(a) - missingCount(b)
  )[0];
  const missing = best.steps.filter((s) => !s.done).map((s) => s.need);
  const label = best.name ? `"${best.name}"` : "its factoring relationship";
  return `${carrierName} can't be switched to Factored yet. ${label} still needs: ${missing.join(", ")}. Complete these under Factoring Companies → Relationships, then try again.`;
}
