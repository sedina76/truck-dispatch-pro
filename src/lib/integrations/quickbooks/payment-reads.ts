import "server-only";
import { createClient } from "@/lib/supabase/server";

// Tolerant, tenant-scoped reads for the QuickBooks payment-import UI. RLS
// (owner/admin + current_org_id) scopes every query. If migration 0118 is
// not applied yet the table does not exist -- every helper returns "no
// imports" rather than throwing, so the invoice page still renders.

export type PaymentImportView = {
  id: string;
  quickbooksPaymentId: string;
  quickbooksInvoiceId: string;
  localPaymentId: string | null;
  appliedAmount: number;
  quickbooksTxnDate: string | null;
  quickbooksReference: string | null;
  quickbooksPaymentMethod: string | null;
  importState: "pending" | "imported" | "failed";
  reconciliationState: "ok" | "reconciliation_required";
  reconciliationDetail: string | null;
  importedAt: string | null;
};

function mapRow(r: Record<string, unknown>): PaymentImportView {
  return {
    id: String(r.id),
    quickbooksPaymentId: String(r.quickbooks_payment_id),
    quickbooksInvoiceId: String(r.quickbooks_invoice_id),
    localPaymentId: (r.local_payment_id as string | null) ?? null,
    appliedAmount: Number(r.applied_amount ?? 0),
    quickbooksTxnDate: (r.quickbooks_txn_date as string | null) ?? null,
    quickbooksReference: (r.quickbooks_reference as string | null) ?? null,
    quickbooksPaymentMethod: (r.quickbooks_payment_method as string | null) ?? null,
    importState: (r.import_state as PaymentImportView["importState"]) ?? "pending",
    reconciliationState: (r.reconciliation_state as PaymentImportView["reconciliationState"]) ?? "ok",
    reconciliationDetail: (r.reconciliation_detail as string | null) ?? null,
    importedAt: (r.imported_at as string | null) ?? null,
  };
}

export async function getInvoicePaymentImports(localInvoiceId: string): Promise<PaymentImportView[]> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("quickbooks_payment_imports")
    .select(
      "id, quickbooks_payment_id, quickbooks_invoice_id, local_payment_id, applied_amount, quickbooks_txn_date, quickbooks_reference, quickbooks_payment_method, import_state, reconciliation_state, reconciliation_detail, imported_at"
    )
    .eq("local_invoice_id", localInvoiceId)
    .order("created_at", { ascending: true });
  if (error || !data) return [];
  return (data as Record<string, unknown>[]).map(mapRow);
}
