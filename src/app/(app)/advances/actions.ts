"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { insertRecord, updateRecord } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";

function advanceValues(formData: FormData) {
  return {
    carrier_id: String(formData.get("carrier_id")),
    driver_id: emptyToNull(formData.get("driver_id")),
    truck_id: emptyToNull(formData.get("truck_id")),
    dispatch_id: emptyToNull(formData.get("dispatch_id")),
    load_id: emptyToNull(formData.get("load_id")),
    expense_type: String(formData.get("expense_type")),
    description: emptyToNull(formData.get("description")),
    amount: toNumber(formData.get("amount")) ?? 0,
    paid_date: emptyToNull(formData.get("paid_date")) ?? new Date().toISOString().slice(0, 10),
    payment_method: emptyToNull(formData.get("payment_method")),
    receipt_url: emptyToNull(formData.get("receipt_url")),
    notes: emptyToNull(formData.get("notes")),
  };
}

export async function createAdvance(formData: FormData) {
  await insertRecord("dispatch_advances", advanceValues(formData), "/advances");
}

export async function updateAdvance(id: string, formData: FormData) {
  await updateRecord("dispatch_advances", id, advanceValues(formData), "/advances");
}

export async function markAdvanceReimbursed(id: string) {
  const supabase = await createClient();
  await supabase.from("dispatch_advances").update({ status: "reimbursed" }).eq("id", id);
  revalidatePath("/advances");
}

export async function markAdvanceWaived(id: string) {
  const supabase = await createClient();
  await supabase.from("dispatch_advances").update({ status: "waived" }).eq("id", id);
  revalidatePath("/advances");
}

// Return void (not the deducted count) even though the RPC yields one --
// these are bound directly as <form action=...>, which requires
// void | Promise<void>. Nothing currently reads the count; revalidatePath
// is what actually surfaces the result (the new deduction line items).
export async function deductAdvancesIntoSettlement(settlementId: string): Promise<void> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("deduct_pending_advances_into_settlement", {
    p_settlement_id: settlementId,
  });
  if (error) throw new Error(error.message);
  revalidatePath(`/settlements/${settlementId}`);
  revalidatePath("/advances");
}

export async function deductAdvancesIntoInvoice(invoiceId: string): Promise<void> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("deduct_pending_advances_into_invoice", {
    p_invoice_id: invoiceId,
  });
  if (error) throw new Error(error.message);
  revalidatePath(`/invoices/${invoiceId}`);
  revalidatePath("/advances");
}
