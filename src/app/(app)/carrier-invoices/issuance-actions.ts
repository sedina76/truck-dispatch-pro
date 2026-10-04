"use server";

import { isCarrierInvoicePilotOperator } from "@/lib/factoring/carrier-invoice-issuance";
import { revalidatePath } from "next/cache";
import { after } from "next/server";
import { autoSendFactorPacket } from "@/lib/carrier-invoices/auto-send";
import { createClient } from "@/lib/supabase/server";
import { ensureCarrierPartyLink } from "@/lib/carrier-invoices/party-link";
import { checkOperationalAccess } from "@/lib/billing/operational-access";
import {
  ISSUANCE_GENERIC_FAILURE,
  isUuid,
  isValidWorkflowKey,
  outcomeFromWorkflow,
  validateIssuanceInput,
  type IssuanceInput,
  type IssuancePreview,
  type WorkflowOutcome,
  type WorkflowResult,
} from "@/lib/factoring/carrier-invoice-issuance";

// Proposal 0157 (D-57) -- carrier-invoice ISSUANCE and REISSUE server actions. Every action calls a SECURITY DEFINER RPC through the CALLER'S OWN session (never service-role): the database derives the
// organization, the role, the per-carrier grant, the billing mode and the factoring relationship from auth.uid(). The client supplies only the carrier, the selected loads and the recipient (or an invoice id),
// an idempotency key and -- for issue/reissue -- the last-seen update time and a reason. There is NO relationship, factor, routing, organization, fee or amount parameter anywhere in this file, so nothing
// here can be substituted. Hiding a button is not security: the RPCs re-check everything.

const fail = (code: string, error = ISSUANCE_GENERIC_FAILURE): WorkflowOutcome => ({ ok: false, code, error });
const isTimestamp = (v: unknown): v is string => typeof v === "string" && v.length > 0 && v.length <= 64 && !Number.isNaN(Date.parse(v));
const cleanReason = (v: unknown): string | null => (typeof v === "string" && v.trim().length > 0 && v.trim().length <= 500 ? v.trim() : null);

async function authed() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  return { supabase, user };
}

function refresh(...invoiceIds: Array<string | undefined>) {
  for (const id of invoiceIds) if (id) revalidatePath(`/carrier-invoices/${id}`);
  revalidatePath("/carrier-invoices");
  revalidatePath("/carrier-invoices/new");
  revalidatePath("/invoices");
}

export type BillableCarrier = { id: string; name: string };
export type BillableLoad = { id: string; loadNumber: string; status: string; brokerId: string | null; customerId: string | null };

/** Read-only pickers through the caller's own RLS-scoped session. They only help the user choose; the RPC re-validates every selection (organization, carrier, recipient, status, amount, duplicates). */
export async function listBillableCarriers(): Promise<BillableCarrier[]> {
  const { supabase, user } = await authed();
  if (!user) return [];
  const { data } = await supabase.from("carriers").select("id, legal_name, dba_name").eq("is_active", true).order("legal_name").limit(500);
  return (data ?? []).map((c) => ({ id: String(c.id), name: String(c.legal_name ?? c.dba_name ?? c.id) }));
}

export async function listBillableLoads(carrierId: string): Promise<BillableLoad[]> {
  if (!isUuid(carrierId)) return [];
  const { supabase, user } = await authed();
  if (!user) return [];
  const { data } = await supabase.from("loads").select("id, load_number, status, broker_id, customer_id").eq("carrier_id", carrierId).in("status", ["delivered", "pod_received"]).order("load_number").limit(200);
  // Only "broker pays the carrier" loads go on the carrier's own invoice
  // (0167/0168); "broker pays us" loads are invoiced to the broker by you.
  const ids = (data ?? []).map((l) => String(l.id));
  const { data: live } = ids.length
    ? await supabase.from("dispatches").select("load_id, proceeds_model").in("load_id", ids).neq("status", "cancelled")
    : { data: [] as { load_id: string; proceeds_model: string | null }[] };
  const carrierPaid = new Set((live ?? []).filter((d) => d.proceeds_model === "carrier_paid_directly").map((d) => String(d.load_id)));
  return (data ?? [])
    .filter((l) => carrierPaid.has(String(l.id)))
    .map((l) => ({ id: String(l.id), loadNumber: String(l.load_number), status: String(l.status), brokerId: l.broker_id ? String(l.broker_id) : null, customerId: l.customer_id ? String(l.customer_id) : null }));
}

export async function previewCarrierInvoiceIssuance(input: IssuanceInput): Promise<IssuancePreview> {
  const bad = validateIssuanceInput(input);
  if (bad) return { success: false, eligible: false, code: bad };
  const { supabase, user } = await authed();
  if (!user) return { success: false, eligible: false, code: "FORBIDDEN" };
  const linkProblem = await ensureCarrierPartyLink(supabase, input);
  if (linkProblem) return { success: false, eligible: false, code: "RECIPIENT_SETUP", message: linkProblem };
  const { data, error } = await supabase.rpc("preview_carrier_invoice_issuance", { p_carrier_id: input.carrierId, p_load_ids: input.loadIds, p_recipient_type: input.recipientType, p_recipient_id: input.recipientId });
  if (error) return { success: false, eligible: false, code: "TRANSPORT", message: ISSUANCE_GENERIC_FAILURE };
  return (data ?? { success: false, eligible: false, code: "UNKNOWN" }) as IssuancePreview;
}

export async function createCarrierInvoiceDraft(input: IssuanceInput, idempotencyKey: string): Promise<WorkflowOutcome> {
  const bad = validateIssuanceInput(input);
  if (bad) return fail(bad);
  if (!isValidWorkflowKey(idempotencyKey)) return fail("INVALID_REQUEST");
  const { supabase, user } = await authed();
  if (!user) return fail("FORBIDDEN", "Not authenticated.");
  const access = await checkOperationalAccess(); // D.2.11 SaaS paywall, as every operational mutation
  if (!access.ok) return fail("FORBIDDEN", "Your organization's subscription does not permit this action.");
  const linkProblem = await ensureCarrierPartyLink(supabase, input);
  if (linkProblem) return fail("RECIPIENT_SETUP", linkProblem);
  const { data, error } = await supabase.rpc("create_carrier_invoice_draft_from_loads", { p_carrier_id: input.carrierId, p_load_ids: input.loadIds, p_recipient_type: input.recipientType, p_recipient_id: input.recipientId, p_idempotency_key: idempotencyKey });
  const outcome = outcomeFromWorkflow(data as WorkflowResult | null, error);
  if (outcome.ok) refresh(outcome.invoiceId);
  return outcome;
}

export async function markCarrierInvoiceReady(invoiceId: string, expectedUpdatedAt: string, idempotencyKey: string): Promise<WorkflowOutcome> {
  if (!isUuid(invoiceId) || !isTimestamp(expectedUpdatedAt) || !isValidWorkflowKey(idempotencyKey)) return fail("INVALID_REQUEST");
  const { supabase, user } = await authed();
  if (!user) return fail("FORBIDDEN", "Not authenticated.");
  const access = await checkOperationalAccess();
  if (!access.ok) return fail("FORBIDDEN", "Your organization's subscription does not permit this action.");
  const { data, error } = await supabase.rpc("mark_carrier_invoice_ready_for_issue", { p_invoice_id: invoiceId, p_expected_updated_at: expectedUpdatedAt, p_idempotency_key: idempotencyKey });
  const outcome = outcomeFromWorkflow(data as WorkflowResult | null, error);
  if (outcome.ok) refresh(invoiceId);
  return outcome;
}

export async function discardCarrierInvoiceDraft(invoiceId: string, expectedUpdatedAt: string, reason: string, idempotencyKey: string): Promise<WorkflowOutcome> {
  const r = cleanReason(reason);
  if (!isUuid(invoiceId) || !isTimestamp(expectedUpdatedAt) || !r || !isValidWorkflowKey(idempotencyKey)) return fail("INVALID_REQUEST");
  const { supabase, user } = await authed();
  if (!user) return fail("FORBIDDEN", "Not authenticated.");
  const access = await checkOperationalAccess();
  if (!access.ok) return fail("FORBIDDEN", "Your organization's subscription does not permit this action.");
  const { data, error } = await supabase.rpc("discard_carrier_invoice_draft", { p_invoice_id: invoiceId, p_expected_updated_at: expectedUpdatedAt, p_reason: r, p_idempotency_key: idempotencyKey });
  const outcome = outcomeFromWorkflow(data as WorkflowResult | null, error);
  if (outcome.ok) refresh(invoiceId);
  return outcome;
}

export async function issueCarrierInvoice(invoiceId: string, expectedUpdatedAt: string, reason: string, idempotencyKey: string): Promise<WorkflowOutcome> {
  const r = cleanReason(reason);
  if (!isUuid(invoiceId) || !isTimestamp(expectedUpdatedAt) || !r || !isValidWorkflowKey(idempotencyKey)) return fail("INVALID_REQUEST");
  const { supabase, user } = await authed();
  if (!user) return fail("FORBIDDEN", "Not authenticated.");
  const { data: invoice } = await supabase.from("carrier_invoices").select("id").eq("id", invoiceId).maybeSingle();
  if (!invoice) return fail("NOT_FOUND", "Carrier invoice not found.");
  const { data: profile } = await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle();
  if (!isCarrierInvoicePilotOperator(profile?.role)) return fail("FORBIDDEN", "Only owners and admins may issue or reissue invoices.");
  const access = await checkOperationalAccess();
  if (!access.ok) return fail("FORBIDDEN", "Your organization's subscription does not permit this action.");
  const { data, error } = await supabase.rpc("issue_prepared_carrier_invoice", { p_invoice_id: invoiceId, p_expected_updated_at: expectedUpdatedAt, p_reason: r, p_idempotency_key: idempotencyKey });
  const outcome = outcomeFromWorkflow(data as WorkflowResult | null, error);
  if (outcome.ok) {
    refresh(invoiceId);
    // Packet complete (PODs verified) and the carrier factors by email? Send it now.
    after(() => autoSendFactorPacket(invoiceId).then(() => undefined));
  }
  return outcome;
}

export async function previewCarrierInvoiceReissue(invoiceId: string): Promise<IssuancePreview> {
  if (!isUuid(invoiceId)) return { success: false, eligible: false, code: "INVALID_REQUEST" };
  const { supabase, user } = await authed();
  if (!user) return { success: false, eligible: false, code: "FORBIDDEN" };
  const { data, error } = await supabase.rpc("preview_carrier_invoice_reissue", { p_invoice_id: invoiceId });
  if (error) return { success: false, eligible: false, code: "TRANSPORT", message: ISSUANCE_GENERIC_FAILURE };
  return (data ?? { success: false, eligible: false, code: "UNKNOWN" }) as IssuancePreview;
}

export async function reissueCarrierInvoice(invoiceId: string, expectedUpdatedAt: string, reason: string, idempotencyKey: string): Promise<WorkflowOutcome> {
  const r = cleanReason(reason);
  if (!isUuid(invoiceId) || !isTimestamp(expectedUpdatedAt) || !r || !isValidWorkflowKey(idempotencyKey)) return fail("INVALID_REQUEST");
  const { supabase, user } = await authed();
  if (!user) return fail("FORBIDDEN", "Not authenticated.");
  const { data: invoice } = await supabase.from("carrier_invoices").select("id").eq("id", invoiceId).maybeSingle();
  if (!invoice) return fail("NOT_FOUND", "Carrier invoice not found.");
  const { data: profile } = await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle();
  if (!isCarrierInvoicePilotOperator(profile?.role)) return fail("FORBIDDEN", "Only owners and admins may issue or reissue invoices.");
  const access = await checkOperationalAccess();
  if (!access.ok) return fail("FORBIDDEN", "Your organization's subscription does not permit this action.");
  const { data, error } = await supabase.rpc("reissue_carrier_invoice", { p_invoice_id: invoiceId, p_expected_updated_at: expectedUpdatedAt, p_reason: r, p_idempotency_key: idempotencyKey });
  const outcome = outcomeFromWorkflow(data as WorkflowResult | null, error);
  if (outcome.ok) {
    refresh(invoiceId, outcome.replacementInvoiceId);
    const replacement = outcome.replacementInvoiceId;
    if (replacement) after(() => autoSendFactorPacket(replacement).then(() => undefined));
  }
  return outcome;
}

