"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { FINANCIAL_ROLES } from "@/lib/auth/require-role";
import { checkOperationalAccess } from "@/lib/billing/operational-access";

export type SubmitInvoiceToFactorResult =
  | { ok: true; data: { factoredInvoiceId: string; status: string } }
  | { ok: false; error: string };

export type FactoringLifecycleResult = { ok: true } | { ok: false; error: string };

// Shared by every Phase 2H.5 lifecycle action below -- identical shape to
// submitInvoiceToFactor()'s own pre-check (fast, friendly "not
// authenticated"/"no permission" message before the round trip; each RPC
// remains the sole authority underneath).
async function requireFactoringReviewAccess(): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not authenticated." };

  // D.2.11 SaaS paywall -- shared gate for every factoring mutation below.
  const billingAccess = await checkOperationalAccess();
  if (!billingAccess.ok) {
    return { ok: false, error: "Your organization's subscription does not permit this action." };
  }

  const { data: profile } = await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle();
  if (!profile || !FINANCIAL_ROLES.includes(profile.role)) {
    return { ok: false, error: "You do not have permission to manage factoring review." };
  }
  return { ok: true };
}

// Postgres unique_violation. THREE different partial unique indexes can
// raise this same code depending on which action/constraint hit it --
// factored_invoices_external_reference_unique (0071, fundFactoredInvoice
// only), factoring_events_reserve_released_reference_unique (0077, real
// factor-reference reuse), and
// factoring_events_reserve_released_idempotency_key_unique (0077, a
// request-level duplicate that release_factoring_reserve()'s own upfront
// check should already have caught as a graceful no-op -- this is a
// defensive backstop, not the primary path). Postgres includes the
// constraint name in the raw message, which is how the idempotency-key
// case is distinguished from the real-reference case below -- the
// message itself is never shown to the user either way.
const UNIQUE_VIOLATION = "23505";

function friendlyLifecycleError(error: { code?: string; message: string }, context?: "funding_reference" | "reserve_release_reference"): string {
  if (error.code === UNIQUE_VIOLATION) {
    if (context === "reserve_release_reference") {
      return "This reference has already been recorded for a reserve release on this factored invoice.";
    }
    return "This reference number is already used by another factored invoice with this factor.";
  }
  // Every other exception these RPCs raise is already a specific,
  // human-readable message (spec section 18's own convention) -- passed
  // straight through, never a raw constraint name or PostgREST internal.
  return error.message;
}

// A duplicate submission of the SAME reserve-release request (same
// idempotency key) is treated as a successful, idempotent acknowledgment
// -- not an error -- matching this app's own existing precedent for a
// lost/duplicate race (generatePacket()'s handling of its own
// unique-version race, billing-packet-actions.ts). In normal operation
// release_factoring_reserve()'s own upfront EXISTS check already returns
// cleanly before ever reaching this constraint; this is a defensive
// backstop for the two paths that should never happen under correct
// application logic.
function isIdempotencyKeyDuplicate(error: { code?: string; message: string }): boolean {
  return error.code === UNIQUE_VIOLATION && error.message.includes("idempotency_key");
}

// Phase 2H.4 -- calls submit_invoice_to_factor() (0073) through the
// CALLER'S OWN session client, never service-role: the RPC is SECURITY
// INVOKER specifically so factored_invoices/factoring_events' own RLS
// (0071 -- FINANCIAL_ROLES, organization_id = current_org_id()) applies
// to its INSERTs exactly as if issued directly, and org/role are derived
// from that session inside the function itself, never accepted as
// arguments here. The pre-check below is redundant with the RPC's own
// checks (kept only for a fast, friendly "not authenticated"/"no
// permission" message before the round trip); the RPC remains the sole
// authority.
export async function submitInvoiceToFactor(invoiceId: string, relationshipId: string): Promise<SubmitInvoiceToFactorResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not authenticated." };

  const billingAccess = await checkOperationalAccess(); // D.2.11 SaaS paywall.
  if (!billingAccess.ok) return { ok: false, error: "Your organization's subscription does not permit this action." };

  const { data: profile } = await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle();
  if (!profile || !FINANCIAL_ROLES.includes(profile.role)) {
    return { ok: false, error: "You do not have permission to submit invoices for factoring." };
  }

  const { data, error } = await supabase.rpc("submit_invoice_to_factor", {
    p_invoice_id: invoiceId,
    p_relationship_id: relationshipId,
  });
  // submit_invoice_to_factor()'s own raise exception messages ARE the
  // human-readable messages spec section 18 lists verbatim -- passed
  // straight through, never a raw constraint name or PostgREST internal
  // (there is no raw constraint this function's own checks don't already
  // preempt with a specific message).
  if (error) return { ok: false, error: error.message };

  // Function returns table(...) -- supabase-js hands back an array of rows.
  const row = Array.isArray(data) ? data[0] : data;
  if (!row?.factored_invoice_id) return { ok: false, error: "Submission did not return a result. Please refresh and check the invoice before retrying." };

  revalidatePath(`/invoices/${invoiceId}`);
  revalidatePath("/invoices");
  return { ok: true, data: { factoredInvoiceId: row.factored_invoice_id, status: row.status } };
}

// ---------------------------------------------------------------------------
// Phase 2H.5 -- factor review/approval/funding lifecycle. Each calls its
// 0076 RPC through the caller's own session client (never service-role),
// same reasoning as submitInvoiceToFactor(): SECURITY INVOKER means
// factored_invoices/factoring_events RLS applies exactly as a direct
// query would, and org/role/current-status are derived and re-verified
// inside the function itself, never trusted from these arguments.
// invoiceId is only ever used to revalidate the page path -- it is not
// passed to the RPC, which resolves everything from
// p_factored_invoice_id alone.
// ---------------------------------------------------------------------------

export async function markFactoredInvoicePending(invoiceId: string, factoredInvoiceId: string): Promise<FactoringLifecycleResult> {
  const auth = await requireFactoringReviewAccess();
  if (!auth.ok) return auth;

  const supabase = await createClient();
  const { error } = await supabase.rpc("mark_factored_invoice_pending", { p_factored_invoice_id: factoredInvoiceId });
  if (error) return { ok: false, error: friendlyLifecycleError(error) };

  revalidatePath(`/invoices/${invoiceId}`);
  return { ok: true };
}

export async function approveFactoredInvoice(invoiceId: string, factoredInvoiceId: string): Promise<FactoringLifecycleResult> {
  const auth = await requireFactoringReviewAccess();
  if (!auth.ok) return auth;

  const supabase = await createClient();
  const { error } = await supabase.rpc("approve_factored_invoice", { p_factored_invoice_id: factoredInvoiceId });
  if (error) return { ok: false, error: friendlyLifecycleError(error) };

  revalidatePath(`/invoices/${invoiceId}`);
  return { ok: true };
}

export async function rejectFactoredInvoice(invoiceId: string, factoredInvoiceId: string, reason: string): Promise<FactoringLifecycleResult> {
  const auth = await requireFactoringReviewAccess();
  if (!auth.ok) return auth;

  const supabase = await createClient();
  const { error } = await supabase.rpc("reject_factored_invoice", { p_factored_invoice_id: factoredInvoiceId, p_reason: reason });
  if (error) return { ok: false, error: friendlyLifecycleError(error) };

  revalidatePath(`/invoices/${invoiceId}`);
  return { ok: true };
}

export async function fundFactoredInvoice(
  invoiceId: string,
  factoredInvoiceId: string,
  actualFundedAmount: number,
  externalReference: string | null
): Promise<FactoringLifecycleResult> {
  const auth = await requireFactoringReviewAccess();
  if (!auth.ok) return auth;

  const supabase = await createClient();
  const { error } = await supabase.rpc("fund_factored_invoice", {
    p_factored_invoice_id: factoredInvoiceId,
    p_actual_funded_amount: actualFundedAmount,
    p_external_reference: externalReference,
  });
  if (error) return { ok: false, error: friendlyLifecycleError(error, "funding_reference") };

  revalidatePath(`/invoices/${invoiceId}`);
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Phase 2H.6 -- normal post-funding settlement lifecycle. Same
// SECURITY INVOKER / caller's-own-session-client reasoning as every
// action above.
// ---------------------------------------------------------------------------

// Deliberately ONE-TIME: report_customer_payment_to_factor() (0077)
// blocks a second call outright once customer_paid_factor_at is set --
// the schema has no child table to represent a second, distinct report,
// so this UI/action never offers or implies partial/incremental customer
// payment entry (spec section 3).
export async function reportCustomerPaymentToFactor(invoiceId: string, factoredInvoiceId: string, amount: number): Promise<FactoringLifecycleResult> {
  const auth = await requireFactoringReviewAccess();
  if (!auth.ok) return auth;

  const supabase = await createClient();
  const { error } = await supabase.rpc("report_customer_payment_to_factor", { p_factored_invoice_id: factoredInvoiceId, p_amount: amount });
  if (error) return { ok: false, error: friendlyLifecycleError(error) };

  revalidatePath(`/invoices/${invoiceId}`);
  return { ok: true };
}

// idempotencyKey MUST be generated once by the caller (factoring-section.tsx,
// held in component state for the lifetime of the open dialog) and resent
// unchanged on every retry of the SAME intended release -- generating a
// key here, inside the action, would defeat the whole mechanism, since a
// fresh invocation (e.g. a browser retry re-running this Server Action)
// would get a fresh key and never deduplicate against the original
// attempt. See release_factoring_reserve() (0077) for the full algorithm.
export async function releaseFactoringReserve(
  invoiceId: string,
  factoredInvoiceId: string,
  amount: number,
  idempotencyKey: string,
  reference: string | null
): Promise<FactoringLifecycleResult> {
  const auth = await requireFactoringReviewAccess();
  if (!auth.ok) return auth;

  const supabase = await createClient();
  const { error } = await supabase.rpc("release_factoring_reserve", {
    p_factored_invoice_id: factoredInvoiceId,
    p_amount: amount,
    p_idempotency_key: idempotencyKey,
    p_reference: reference,
  });
  if (error) {
    if (isIdempotencyKeyDuplicate(error)) {
      revalidatePath(`/invoices/${invoiceId}`);
      return { ok: true }; // idempotent acknowledgment, not an error -- see header comment
    }
    return { ok: false, error: friendlyLifecycleError(error, "reserve_release_reference") };
  }

  revalidatePath(`/invoices/${invoiceId}`);
  return { ok: true };
}

export async function closeFactoredInvoice(invoiceId: string, factoredInvoiceId: string): Promise<FactoringLifecycleResult> {
  const auth = await requireFactoringReviewAccess();
  if (!auth.ok) return auth;

  const supabase = await createClient();
  const { error } = await supabase.rpc("close_factored_invoice", { p_factored_invoice_id: factoredInvoiceId });
  if (error) return { ok: false, error: friendlyLifecycleError(error) };

  revalidatePath(`/invoices/${invoiceId}`);
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Phase 2H.7 -- exception lifecycle (dispute / recourse / chargeback /
// buyback). Same SECURITY INVOKER / caller's-own-session-client reasoning
// as every action above. None of these five RPCs take a caller-supplied
// idempotency key -- each one moves the row OUT of the exact status its
// own precondition requires, so an exact retry after commit fails cleanly
// on its own status pre-check (0078's own header comment has the full
// reasoning). This does not change reserve release's own idempotency
// design above in any way.
// ---------------------------------------------------------------------------

export async function markFactoredInvoiceDisputed(
  invoiceId: string,
  factoredInvoiceId: string,
  reason: string,
  reference: string | null
): Promise<FactoringLifecycleResult> {
  const auth = await requireFactoringReviewAccess();
  if (!auth.ok) return auth;

  const supabase = await createClient();
  const { error } = await supabase.rpc("mark_factored_invoice_disputed", {
    p_factored_invoice_id: factoredInvoiceId,
    p_reason: reason,
    p_reference: reference,
  });
  if (error) return { ok: false, error: friendlyLifecycleError(error) };

  revalidatePath(`/invoices/${invoiceId}`);
  return { ok: true };
}

export async function resolveFactoringDispute(invoiceId: string, factoredInvoiceId: string, notes: string | null): Promise<FactoringLifecycleResult> {
  const auth = await requireFactoringReviewAccess();
  if (!auth.ok) return auth;

  const supabase = await createClient();
  const { error } = await supabase.rpc("resolve_factoring_dispute", { p_factored_invoice_id: factoredInvoiceId, p_notes: notes });
  if (error) return { ok: false, error: friendlyLifecycleError(error) };

  revalidatePath(`/invoices/${invoiceId}`);
  return { ok: true };
}

export async function startFactoringRecourse(
  invoiceId: string,
  factoredInvoiceId: string,
  amount: number,
  reason: string,
  reference: string | null
): Promise<FactoringLifecycleResult> {
  const auth = await requireFactoringReviewAccess();
  if (!auth.ok) return auth;

  const supabase = await createClient();
  const { error } = await supabase.rpc("start_factoring_recourse", {
    p_factored_invoice_id: factoredInvoiceId,
    p_amount: amount,
    p_reason: reason,
    p_reference: reference,
  });
  if (error) return { ok: false, error: friendlyLifecycleError(error) };

  revalidatePath(`/invoices/${invoiceId}`);
  return { ok: true };
}

export async function recordFactoringChargeback(
  invoiceId: string,
  factoredInvoiceId: string,
  amount: number,
  reference: string | null,
  reason: string | null
): Promise<FactoringLifecycleResult> {
  const auth = await requireFactoringReviewAccess();
  if (!auth.ok) return auth;

  const supabase = await createClient();
  const { error } = await supabase.rpc("record_factoring_chargeback", {
    p_factored_invoice_id: factoredInvoiceId,
    p_amount: amount,
    p_reference: reference,
    p_reason: reason,
  });
  if (error) return { ok: false, error: friendlyLifecycleError(error) };

  revalidatePath(`/invoices/${invoiceId}`);
  return { ok: true };
}

export async function recordFactoringBuyback(
  invoiceId: string,
  factoredInvoiceId: string,
  amount: number,
  reference: string | null,
  notes: string | null
): Promise<FactoringLifecycleResult> {
  const auth = await requireFactoringReviewAccess();
  if (!auth.ok) return auth;

  const supabase = await createClient();
  const { error } = await supabase.rpc("record_factoring_buyback", {
    p_factored_invoice_id: factoredInvoiceId,
    p_amount: amount,
    p_reference: reference,
    p_notes: notes,
  });
  if (error) return { ok: false, error: friendlyLifecycleError(error) };

  revalidatePath(`/invoices/${invoiceId}`);
  return { ok: true };
}
