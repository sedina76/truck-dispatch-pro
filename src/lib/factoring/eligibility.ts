// Phase 2H.4 -- UI-side pre-check ONLY. Mirrors the exact hard gates
// submit_invoice_to_factor() (0073) enforces inside its own transaction --
// this exists purely so the Invoice Detail page can show/hide the "Submit
// to Factor" action and a clear reason without a round trip, never as the
// authoritative rule. The database RPC re-validates every one of these
// itself and is what actually decides; this function must never drift
// into being trusted on its own (see submit_invoice_to_factor()'s header
// comment in 0073 for the full reasoning behind each gate, including why
// 'partially_paid' is deliberately excluded rather than guessing a
// balance-due-based face value formula).
export type FactoringEligibilityInput = {
  status: string;
  amountPaid: number;
};

export type FactoringEligibility = { eligible: true } | { eligible: false; reason: string };

const ELIGIBLE_STATUSES = new Set(["sent", "viewed"]);

export function evaluateFactoringEligibility(invoice: FactoringEligibilityInput): FactoringEligibility {
  if (!ELIGIBLE_STATUSES.has(invoice.status) || invoice.amountPaid !== 0) {
    return { eligible: false, reason: "This invoice is not eligible for factoring. Only sent or viewed invoices with no payments recorded can be submitted." };
  }
  return { eligible: true };
}

// Terminal-for-resubmission set -- the EXACT predicate
// factored_invoices_one_active_per_invoice (0071) uses, not a re-guess.
// A factored_invoices row in any OTHER status still occupies the "one
// active submission" slot.
export function isNonTerminalFactoredInvoiceStatus(status: string): boolean {
  return status !== "rejected" && status !== "cancelled";
}
