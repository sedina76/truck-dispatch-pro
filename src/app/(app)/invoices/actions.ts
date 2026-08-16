"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { updateRecord, getCurrentOrgId } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";

function invoiceValues(formData: FormData) {
  return {
    invoice_number: String(formData.get("invoice_number")),
    broker_id: emptyToNull(formData.get("broker_id")),
    customer_id: emptyToNull(formData.get("customer_id")),
    load_id: emptyToNull(formData.get("load_id")),
    status: String(formData.get("status") || "draft"),
    bill_to_name: String(formData.get("bill_to_name")),
    bill_to_email: emptyToNull(formData.get("bill_to_email")),
    bill_to_address: emptyToNull(formData.get("bill_to_address")),
    due_date: emptyToNull(formData.get("due_date")),
    notes: emptyToNull(formData.get("notes")),
  };
}

// Manual "Create Invoice" (Load Detail -> Create Invoice, or Finance ->
// Invoices -> New Invoice with a load selected): the load's own unique
// index on invoices.load_id (0022_auto_invoice_on_delivery.sql) is what
// actually prevents a duplicate under a race -- this is the one manual
// entry path into the same invoices table the auto-invoice trigger writes
// to, not a second invoice system. When a load is attached, its rate
// becomes the invoice's one starting line item (still editable afterward
// from the invoice detail page, exactly like every other invoice).
export async function createInvoice(formData: FormData) {
  const values = invoiceValues(formData);
  const rate = toNumber(formData.get("rate"));
  const loadNumber = emptyToNull(formData.get("load_id")) ? await lookupLoadNumber(values.load_id!) : null;

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const { data, error } = await supabase
    .from("invoices")
    .insert({ ...values, organization_id: organizationId })
    .select("id")
    .single();
  if (error) throw new Error(error.message);

  if (values.load_id && rate) {
    await supabase.from("invoice_line_items").insert({
      organization_id: organizationId,
      invoice_id: data.id,
      description: `Freight charges -- Load ${loadNumber ?? ""}`.trim(),
      quantity: 1,
      unit_price: rate,
      sort_order: 0,
    });
  }

  await supabase.rpc("log_activity", { p_entity_type: "invoice", p_entity_id: data.id, p_action: "created" });
  revalidatePath("/invoices");
  if (values.load_id) revalidatePath(`/loads/${values.load_id}`);
  redirect("/invoices");
}

async function lookupLoadNumber(loadId: string): Promise<string | null> {
  const supabase = await createClient();
  const { data } = await supabase.from("loads").select("load_number").eq("id", loadId).maybeSingle();
  return data?.load_number ?? null;
}

export async function updateInvoice(id: string, formData: FormData) {
  await updateRecord("invoices", id, invoiceValues(formData), "/invoices");
}

export async function addInvoiceLineItem(invoiceId: string, formData: FormData) {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  await supabase.from("invoice_line_items").insert({
    organization_id: organizationId,
    invoice_id: invoiceId,
    description: String(formData.get("description")),
    quantity: toNumber(formData.get("quantity")) ?? 1,
    unit_price: toNumber(formData.get("unit_price")) ?? 0,
  });
  revalidatePath(`/invoices/${invoiceId}`);
}
