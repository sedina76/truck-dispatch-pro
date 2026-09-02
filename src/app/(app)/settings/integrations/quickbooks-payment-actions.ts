"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { getQuickbooksAccessToken } from "./quickbooks-actions";
import {
  getInvoiceStatusById,
  getPaymentsForInvoice,
  getInvoicePaymentById,
  type QboInvoicePayment,
} from "@/lib/integrations/providers/quickbooks";

// QuickBooks PAYMENT SYNC MVP (SANDBOX). Two server actions:
//   * refreshQuickbooksInvoiceStatus(invoiceId) -- 100% READ-ONLY. Reads
//     the QBO invoice + its QBO Payments, flags a previously-imported
//     payment that now looks voided/removed/re-allocated. Never creates a
//     local payment, never touches invoices.amount_paid, never writes to
//     QuickBooks.
//   * importQuickbooksPayment(invoiceId, quickbooksPaymentId) -- the ONLY
//     action that creates a local payment. Re-validates against QuickBooks,
//     blocks duplicates (DB UNIQUE + re-read), blocks a likely-existing
//     manual payment, blocks overpayment, then inserts ONE row into
//     public.payments through the existing authoritative path
//     (guard_payment_amount() + apply_payment_to_invoice() do the rest).
//
// Every action: owner/admin at the app layer, organization resolved from
// the authenticated session (never a browser param), all writes RLS-scoped
// to current_org_id(). No token reaches the client. Requires migration
// 0118 -- until it is applied the reads/writes return NOT_SET_UP which the
// UI surfaces as "QuickBooks payment sync is not set up yet".

const IMPORTABLE_INVOICE_STATUSES = new Set(["sent", "viewed", "overdue", "partially_paid"]);
const STALE_PENDING_MINUTES = 3;
const LOCAL_MATCH_DAYS = 5;

type ActionFail = { ok: false; code: string; message: string };
type ActionResult<T = Record<string, never>> = ({ ok: true } & T) | ActionFail;

type PaymentView = {
  quickbooksPaymentId: string;
  txnDate: string | null;
  appliedToInvoice: number;
  totalAmt: number;
  referenceNumber: string | null;
  paymentMethod: string | null;
  voided: boolean;
  importState: "none" | "pending" | "imported" | "failed";
  reconciliationState: "ok" | "reconciliation_required";
  localPaymentId: string | null;
  importedAt: string | null;
};

type RefreshOk = {
  qboInvoice: { docNumber: string | null; totalAmt: number; balance: number } | null;
  payments: PaymentView[];
};

async function requireOwnerAdminOrg(): Promise<
  { supabase: Awaited<ReturnType<typeof createClient>>; orgId: string; userId: string | null } | { error: ActionFail }
> {
  const supabase = await createClient();
  const { data: allowed } = await supabase.rpc("has_role", { p_roles: ["owner", "admin"] });
  if (!allowed) return { error: { ok: false, code: "FORBIDDEN", message: "Only an owner or admin can import QuickBooks payments." } };
  let orgId: string;
  try {
    orgId = await getCurrentOrgId();
  } catch {
    return { error: { ok: false, code: "NO_ORG", message: "No organization context." } };
  }
  const {
    data: { user },
  } = await supabase.auth.getUser();
  return { supabase, orgId, userId: user?.id ?? null };
}

function friendlyReauth(): ActionFail {
  return { ok: false, code: "QBO_REAUTH", message: "QuickBooks needs to be reconnected. Open the QuickBooks integration page." };
}

function notSetUp(message: string): boolean {
  return /relation .* does not exist/i.test(message);
}

type SyncedInvoiceCtx = {
  invoice: { id: string; status: string; balance_due: number; broker_id: string | null; customer_id: string | null };
  quickbooksInvoiceId: string;
  quickbooksCustomerId: string;
};

// Shared load + guard: local invoice (RLS/org scoped), its synced QBO
// invoice id, and the mapped QBO customer id for the invoice's party.
async function loadSyncedInvoice(
  supabase: Awaited<ReturnType<typeof createClient>>,
  orgId: string,
  invoiceId: string
): Promise<SyncedInvoiceCtx | ActionFail> {
  const { data: inv } = await supabase
    .from("invoices")
    .select("id, status, balance_due, broker_id, customer_id")
    .eq("id", invoiceId)
    .eq("organization_id", orgId)
    .maybeSingle();
  if (!inv) return { ok: false, code: "NOT_FOUND", message: "This invoice is not available." };

  const { data: sync, error: syncErr } = await supabase
    .from("quickbooks_invoice_syncs")
    .select("sync_status, quickbooks_invoice_id")
    .eq("organization_id", orgId)
    .eq("invoice_id", invoiceId)
    .maybeSingle();
  if (syncErr && notSetUp(syncErr.message)) {
    return { ok: false, code: "NOT_SET_UP", message: "Send this invoice to QuickBooks first." };
  }
  if (!sync || sync.sync_status !== "synced" || !sync.quickbooks_invoice_id) {
    return { ok: false, code: "NOT_SYNCED", message: "Send this invoice to QuickBooks before importing payments." };
  }

  const partyType = inv.broker_id ? "broker" : inv.customer_id ? "customer" : null;
  const partyId = inv.broker_id ?? inv.customer_id ?? null;
  if (!partyType || !partyId) {
    return { ok: false, code: "NO_PARTY", message: "This invoice has no customer or broker." };
  }
  const { data: mapping, error: mapErr } = await supabase
    .from("quickbooks_customer_mappings")
    .select("quickbooks_customer_id")
    .eq("organization_id", orgId)
    .eq("local_entity_type", partyType)
    .eq("local_entity_id", partyId)
    .maybeSingle();
  if (mapErr && notSetUp(mapErr.message)) {
    return { ok: false, code: "NOT_SET_UP", message: "QuickBooks sync is not set up yet." };
  }
  if (!mapping) return { ok: false, code: "CUSTOMER_NOT_MAPPED", message: "Map this customer to QuickBooks first." };

  return {
    invoice: {
      id: inv.id,
      status: inv.status,
      balance_due: Number(inv.balance_due),
      broker_id: inv.broker_id,
      customer_id: inv.customer_id,
    },
    quickbooksInvoiceId: sync.quickbooks_invoice_id,
    quickbooksCustomerId: mapping.quickbooks_customer_id,
  };
}

// ---------------------------------------------------------------------------
// READ-ONLY refresh / discovery
// ---------------------------------------------------------------------------

export async function refreshQuickbooksInvoiceStatus(invoiceId: string): Promise<ActionResult<RefreshOk>> {
  const ctx = await requireOwnerAdminOrg();
  if ("error" in ctx) return ctx.error;
  const { supabase, orgId } = ctx;

  const synced = await loadSyncedInvoice(supabase, orgId, invoiceId);
  if ("ok" in synced) return synced;

  const token = await getQuickbooksAccessToken();
  if (!token) return { ok: false, code: "QBO_DISCONNECTED", message: "QuickBooks is not connected for this organization." };

  const [invRes, payRes] = await Promise.all([
    getInvoiceStatusById(token.accessToken, token.realmId, synced.quickbooksInvoiceId),
    getPaymentsForInvoice(token.accessToken, token.realmId, synced.quickbooksCustomerId, synced.quickbooksInvoiceId),
  ]);
  if (!invRes.ok) return invRes.reauthRequired ? friendlyReauth() : { ok: false, code: invRes.code, message: invRes.message };
  if (!payRes.ok) return payRes.reauthRequired ? friendlyReauth() : { ok: false, code: payRes.code, message: payRes.message };

  // Existing import rows for this invoice.
  const { data: importRows, error: impErr } = await supabase
    .from("quickbooks_payment_imports")
    .select("id, quickbooks_payment_id, local_payment_id, applied_amount, import_state, reconciliation_state, imported_at")
    .eq("organization_id", orgId)
    .eq("local_invoice_id", invoiceId);
  if (impErr && notSetUp(impErr.message)) {
    return { ok: false, code: "NOT_SET_UP", message: "QuickBooks payment sync is not set up yet (migration 0118 pending)." };
  }
  const imports = (importRows ?? []) as {
    id: string;
    quickbooks_payment_id: string;
    local_payment_id: string | null;
    applied_amount: number;
    import_state: string;
    reconciliation_state: string;
    imported_at: string | null;
  }[];
  const qboById = new Map(payRes.payments.map((p) => [p.id, p]));

  // Reconciliation detection (READ-ONLY w.r.t. the local payment): for each
  // row already imported, does the QBO payment still exist, still link to
  // this invoice, and still apply the same amount? If not -> flag it. Never
  // reverse or delete anything automatically.
  for (const row of imports) {
    if (row.import_state !== "imported") continue;
    const live = qboById.get(row.quickbooks_payment_id);
    let detail: string | null = null;
    if (!live) detail = "The QuickBooks payment is no longer visible against this invoice (voided, deleted, or re-allocated).";
    else if (live.voided) detail = "The QuickBooks payment has been voided.";
    else if (Math.abs(live.appliedToInvoice - Number(row.applied_amount)) > 0.005)
      detail = `QuickBooks now applies $${live.appliedToInvoice.toFixed(2)} to this invoice (imported as $${Number(row.applied_amount).toFixed(2)}).`;

    const nextState = detail ? "reconciliation_required" : "ok";
    if (nextState !== row.reconciliation_state || detail) {
      await supabase
        .from("quickbooks_payment_imports")
        .update({
          reconciliation_state: nextState,
          reconciliation_detail: detail,
          last_verified_at: new Date().toISOString(),
        })
        .eq("id", row.id);
      if (detail) {
        await supabase.rpc("log_activity", {
          p_entity_type: "invoice",
          p_entity_id: invoiceId,
          p_action: "quickbooks_payment_reconciliation_required",
          p_changes: { quickbooks_payment_id: row.quickbooks_payment_id, detail },
          p_organization_id: orgId,
        });
      }
    } else {
      await supabase.from("quickbooks_payment_imports").update({ last_verified_at: new Date().toISOString() }).eq("id", row.id);
    }
  }

  const importByPaymentId = new Map(imports.map((r) => [r.quickbooks_payment_id, r]));
  const payments: PaymentView[] = payRes.payments.map((p) => {
    const row = importByPaymentId.get(p.id);
    return {
      quickbooksPaymentId: p.id,
      txnDate: p.txnDate,
      appliedToInvoice: p.appliedToInvoice,
      totalAmt: p.totalAmt,
      referenceNumber: p.referenceNumber,
      paymentMethod: p.paymentMethod,
      voided: p.voided,
      importState: row ? (row.import_state as PaymentView["importState"]) : "none",
      reconciliationState: (row?.reconciliation_state as PaymentView["reconciliationState"]) ?? "ok",
      localPaymentId: row?.local_payment_id ?? null,
      importedAt: row?.imported_at ?? null,
    };
  });

  revalidatePath(`/invoices/${invoiceId}`);
  return {
    ok: true,
    qboInvoice: invRes.invoice
      ? { docNumber: invRes.invoice.docNumber, totalAmt: invRes.invoice.totalAmt, balance: invRes.invoice.balance }
      : null,
    payments,
  };
}

// ---------------------------------------------------------------------------
// EXPLICIT import (the only local write)
// ---------------------------------------------------------------------------

const PAYMENT_METHOD_MAP: Record<string, string> = {
  cash: "cash",
  check: "check",
  cheque: "check",
  "credit card": "credit_card",
  creditcard: "credit_card",
  ach: "ach",
  "e-check": "ach",
  eft: "ach",
  wire: "wire",
  "wire transfer": "wire",
};

function mapMethod(qboMethod: string | null): string {
  if (!qboMethod) return "other";
  return PAYMENT_METHOD_MAP[qboMethod.trim().toLowerCase()] ?? "other";
}

function looksLikeSameLocalPayment(
  local: { amount: number; received_at: string; reference_number: string | null },
  qbo: QboInvoicePayment
): boolean {
  if (Math.abs(Number(local.amount) - qbo.appliedToInvoice) > 0.005) return false;
  if (qbo.referenceNumber && local.reference_number && qbo.referenceNumber.trim() === local.reference_number.trim()) return true;
  if (!qbo.txnDate) return false;
  const days = Math.abs(new Date(local.received_at).getTime() - new Date(qbo.txnDate).getTime()) / 86_400_000;
  return days <= LOCAL_MATCH_DAYS;
}

export async function importQuickbooksPayment(
  invoiceId: string,
  quickbooksPaymentId: string
): Promise<ActionResult<{ alreadyImported: boolean; localPaymentId: string | null; appliedAmount: number }>> {
  const ctx = await requireOwnerAdminOrg();
  if ("error" in ctx) return ctx.error;
  const { supabase, orgId, userId } = ctx;

  if (!quickbooksPaymentId || !quickbooksPaymentId.trim()) {
    return { ok: false, code: "BAD_INPUT", message: "No QuickBooks payment was selected." };
  }

  const synced = await loadSyncedInvoice(supabase, orgId, invoiceId);
  if ("ok" in synced) return synced;

  // (11) local invoice must not be void; must be in an importable status.
  if (synced.invoice.status === "void") {
    return { ok: false, code: "INVOICE_VOID", message: "This invoice is void -- a payment cannot be imported against it." };
  }
  if (!IMPORTABLE_INVOICE_STATUSES.has(synced.invoice.status)) {
    return {
      ok: false,
      code: "BAD_STATUS",
      message: "This invoice is not in an importable status (Sent, Viewed, Overdue, or Partially Paid).",
    };
  }

  const token = await getQuickbooksAccessToken();
  if (!token) return { ok: false, code: "QBO_DISCONNECTED", message: "QuickBooks is not connected for this organization." };

  // (7)(8)(9) re-fetch the QBO payment and revalidate the linkage + amount.
  const payRes = await getInvoicePaymentById(token.accessToken, token.realmId, quickbooksPaymentId, synced.quickbooksInvoiceId);
  if (!payRes.ok) return payRes.reauthRequired ? friendlyReauth() : { ok: false, code: payRes.code, message: payRes.message };
  const qbo = payRes.payment;
  if (!qbo) return { ok: false, code: "QBO_PAYMENT_NOT_FOUND", message: "That QuickBooks payment no longer exists." };
  if (qbo.voided) return { ok: false, code: "QBO_PAYMENT_VOIDED", message: "That QuickBooks payment has been voided." };
  if (!qbo.linkedInvoiceIds.includes(synced.quickbooksInvoiceId)) {
    return { ok: false, code: "NOT_LINKED", message: "That QuickBooks payment is not applied to this invoice." };
  }
  const applied = Number(qbo.appliedToInvoice.toFixed(2));
  if (!(applied > 0)) {
    return { ok: false, code: "ZERO_APPLIED", message: "QuickBooks applies $0.00 of that payment to this invoice." };
  }

  // (12) overpayment -- block, don't truncate. (The DB guard would also
  // block it; this gives the friendly reconciliation message and avoids a
  // stranded pending row.)
  if (applied > synced.invoice.balance_due + 0.005) {
    return {
      ok: false,
      code: "OVERPAYMENT",
      message: `QuickBooks applied $${applied.toFixed(2)} but only $${synced.invoice.balance_due.toFixed(
        2
      )} is left on this invoice. Reconciliation required -- the payment was not imported.`,
    };
  }

  // (10) duplicate: hard DB key is (org, qbo_payment_id, qbo_invoice_id);
  // check it first for a friendly result, then rely on the constraint.
  const { data: existing, error: exErr } = await supabase
    .from("quickbooks_payment_imports")
    .select("id, import_state, local_payment_id, imported_at, updated_at")
    .eq("organization_id", orgId)
    .eq("quickbooks_payment_id", quickbooksPaymentId)
    .eq("quickbooks_invoice_id", synced.quickbooksInvoiceId)
    .maybeSingle();
  if (exErr && notSetUp(exErr.message)) {
    return { ok: false, code: "NOT_SET_UP", message: "QuickBooks payment sync is not set up yet (migration 0118 pending)." };
  }

  let importRowId: string | null = existing?.id ?? null;
  if (existing) {
    if (existing.import_state === "imported") {
      return { ok: true, alreadyImported: true, localPaymentId: existing.local_payment_id, appliedAmount: applied };
    }
    const stale = Date.now() - new Date(existing.updated_at).getTime() > STALE_PENDING_MINUTES * 60_000;
    if (existing.import_state === "pending" && !stale) {
      return { ok: false, code: "IN_PROGRESS", message: "This payment is already being imported. Refresh in a moment." };
    }
    // failed or stale pending -> reclaim.
    await supabase
      .from("quickbooks_payment_imports")
      .update({ import_state: "pending", last_error: null, applied_amount: applied })
      .eq("id", existing.id);
  }

  // Existing-local-payment conflict (spec: this is critical). A posted
  // payment on this invoice, with no QBO provenance, that looks like the
  // same money -> STOP and require explicit reconciliation.
  const { data: localPayments } = await supabase
    .from("payments")
    .select("id, amount, received_at, reference_number, payment_number")
    .eq("invoice_id", invoiceId)
    .eq("status", "posted");
  const { data: claimed } = await supabase
    .from("quickbooks_payment_imports")
    .select("local_payment_id")
    .eq("organization_id", orgId)
    .not("local_payment_id", "is", null);
  const claimedIds = new Set((claimed ?? []).map((c) => c.local_payment_id as string));
  const conflict = (localPayments ?? []).find(
    (lp) => !claimedIds.has(lp.id) && looksLikeSameLocalPayment(lp, qbo)
  );
  if (conflict) {
    await supabase.rpc("log_activity", {
      p_entity_type: "invoice",
      p_entity_id: invoiceId,
      p_action: "quickbooks_payment_local_duplicate_detected",
      p_changes: { quickbooks_payment_id: quickbooksPaymentId, local_payment_number: conflict.payment_number, applied_amount: applied },
      p_organization_id: orgId,
    });
    return {
      ok: false,
      code: "LOCAL_PAYMENT_CONFLICT",
      message: `Possible existing Truck Dispatch Pro payment found (${conflict.payment_number}, $${Number(conflict.amount).toFixed(
        2
      )}). It was not imported. Void that payment first if it is the same money, then import again.`,
    };
  }

  // Claim the idempotency lock (pending row) BEFORE creating the payment.
  if (!importRowId) {
    const { data: claimRow, error: claimErr } = await supabase
      .from("quickbooks_payment_imports")
      .insert({
        organization_id: orgId,
        quickbooks_payment_id: quickbooksPaymentId,
        quickbooks_invoice_id: synced.quickbooksInvoiceId,
        local_invoice_id: invoiceId,
        applied_amount: applied,
        quickbooks_txn_date: qbo.txnDate,
        quickbooks_reference: qbo.referenceNumber,
        quickbooks_payment_method: qbo.paymentMethod,
        import_state: "pending",
        imported_by: userId,
      })
      .select("id")
      .single();
    if (claimErr) {
      if (notSetUp(claimErr.message)) {
        return { ok: false, code: "NOT_SET_UP", message: "QuickBooks payment sync is not set up yet (migration 0118 pending)." };
      }
      if (claimErr.code === "23505") {
        const { data: raced } = await supabase
          .from("quickbooks_payment_imports")
          .select("import_state, local_payment_id")
          .eq("organization_id", orgId)
          .eq("quickbooks_payment_id", quickbooksPaymentId)
          .eq("quickbooks_invoice_id", synced.quickbooksInvoiceId)
          .single();
        if (raced?.import_state === "imported") {
          return { ok: true, alreadyImported: true, localPaymentId: raced.local_payment_id, appliedAmount: applied };
        }
        return { ok: false, code: "IN_PROGRESS", message: "This payment is already being imported. Refresh in a moment." };
      }
      return { ok: false, code: "DB_ERROR", message: "Could not start the payment import." };
    }
    importRowId = claimRow.id;
  }

  async function markFailed(code: string, message: string): Promise<ActionFail> {
    if (importRowId) {
      await supabase
        .from("quickbooks_payment_imports")
        .update({ import_state: "failed", last_error: `${code}: ${message}`.slice(0, 500) })
        .eq("id", importRowId);
    }
    return { ok: false, code, message };
  }

  // Create the local payment through the authoritative path. The DB
  // triggers (guard_payment_amount overpayment/void/amount<=0, then
  // apply_payment_to_invoice rollup) are the real authority.
  const { data: created, error: payErr } = await supabase
    .from("payments")
    .insert({
      organization_id: orgId,
      invoice_id: invoiceId,
      amount: applied,
      method: mapMethod(qbo.paymentMethod),
      received_at: qbo.txnDate ? new Date(qbo.txnDate).toISOString() : new Date().toISOString(),
      reference_number: qbo.referenceNumber ?? `QuickBooks Payment ${quickbooksPaymentId}`,
      notes: `Imported from QuickBooks (Payment ${quickbooksPaymentId}${
        qbo.totalAmt && Math.abs(qbo.totalAmt - applied) > 0.005 ? `, $${qbo.totalAmt.toFixed(2)} total across invoices` : ""
      }).`,
      recorded_by: userId,
    })
    .select("id, payment_number")
    .single();
  if (payErr || !created) {
    return markFailed("PAYMENT_REJECTED", payErr?.message ?? "The payment could not be recorded.");
  }

  // Finalize provenance.
  const { error: finErr } = await supabase
    .from("quickbooks_payment_imports")
    .update({
      local_payment_id: created.id,
      import_state: "imported",
      reconciliation_state: "ok",
      reconciliation_detail: null,
      last_error: null,
      imported_at: new Date().toISOString(),
      last_verified_at: new Date().toISOString(),
    })
    .eq("id", importRowId);
  if (finErr) {
    // The local payment exists and counts; only the provenance link
    // failed. Report clearly -- a retry will not double-import because the
    // (org, payment, invoice) row is already present and a re-run adopts
    // it, and the local-duplicate check would also catch the new payment.
    return {
      ok: false,
      code: "PARTIAL_IMPORT",
      message: `The payment (${created.payment_number}) was recorded but its QuickBooks link could not be saved. Run "Refresh QuickBooks Status" to finish linking it.`,
    };
  }

  await supabase.rpc("log_activity", {
    p_entity_type: "invoice",
    p_entity_id: invoiceId,
    p_action: "quickbooks_payment_imported",
    p_changes: {
      quickbooks_payment_id: quickbooksPaymentId,
      quickbooks_invoice_id: synced.quickbooksInvoiceId,
      local_payment_number: created.payment_number,
      applied_amount: applied,
    },
    p_organization_id: orgId,
  });

  revalidatePath(`/invoices/${invoiceId}`);
  revalidatePath("/payments");
  revalidatePath("/accounts-receivable");
  return { ok: true, alreadyImported: false, localPaymentId: created.id, appliedAmount: applied };
}
