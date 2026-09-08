"use server";

import { revalidatePath } from "next/cache";
import { requireOperationalAccess } from "@/lib/billing/operational-access";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";
import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

// Expense & Cost Management (0040_expense_cost_management.sql). Bespoke
// actions, not the generic insertRecord/updateRecord helper -- the
// approve/pay/void lifecycle is enforced by guard_expense_lifecycle (a DB
// trigger, not a wrapper RPC), so these actions just write the base
// columns and let the trigger populate approved_at/approved_by/etc and
// reject anything that isn't a legal transition.

function expenseValues(formData: FormData) {
  return {
    scope: String(formData.get("scope") || "general"),
    category: String(formData.get("category") || "other"),
    amount: toNumber(formData.get("amount")) ?? 0,
    tax_amount: toNumber(formData.get("tax_amount")) ?? 0,
    expense_date: String(formData.get("expense_date") || new Date().toISOString().slice(0, 10)),
    vendor_name: emptyToNull(formData.get("vendor_name")),
    description: emptyToNull(formData.get("description")),
    payment_method: emptyToNull(formData.get("payment_method")),
    reference_number: emptyToNull(formData.get("reference_number")),
    billable_to_customer: formData.get("billable_to_customer") === "on",
    notes: emptyToNull(formData.get("notes")),
    load_id: emptyToNull(formData.get("load_id")),
    dispatch_id: emptyToNull(formData.get("dispatch_id")),
    truck_id: emptyToNull(formData.get("truck_id")),
    trailer_id: emptyToNull(formData.get("trailer_id")),
    driver_id: emptyToNull(formData.get("driver_id")),
    carrier_id: emptyToNull(formData.get("carrier_id")),
    fuel_log_id: emptyToNull(formData.get("fuel_log_id")),
  };
}

export async function createExpense(formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data, error } = await supabase
    .from("expenses")
    .insert({
      organization_id: organizationId,
      status: "draft",
      recorded_by: user?.id ?? null,
      ...expenseValues(formData),
    })
    .select("id")
    .single();
  if (error) throw new Error(error.message);

  revalidatePath("/expenses");
  const returnTo = String(formData.get("return_to") || "");
  redirect(returnTo || `/expenses/${data.id}`);
}

export async function updateExpense(id: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const { error } = await supabase.from("expenses").update(expenseValues(formData)).eq("id", id);
  if (error) throw new Error(error.message);
  revalidatePath(`/expenses/${id}`);
  revalidatePath("/expenses");
}

export async function submitExpense(id: string) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const { error } = await supabase.from("expenses").update({ status: "submitted" }).eq("id", id);
  if (error) throw new Error(error.message);
  revalidatePath(`/expenses/${id}`);
}

export async function approveExpense(id: string) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const { error } = await supabase.from("expenses").update({ status: "approved" }).eq("id", id);
  if (error) throw new Error(error.message);
  revalidatePath(`/expenses/${id}`);
  revalidatePath("/expenses");
}

export async function markExpensePaid(id: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const { error } = await supabase
    .from("expenses")
    .update({
      status: "paid",
      payment_method: emptyToNull(formData.get("payment_method")),
      reference_number: emptyToNull(formData.get("reference_number")),
    })
    .eq("id", id);
  if (error) throw new Error(error.message);
  revalidatePath(`/expenses/${id}`);
  revalidatePath("/expenses");
}

export async function voidExpense(id: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const reason = String(formData.get("void_reason") || "").trim();
  if (!reason) throw new Error("A reason is required to void an expense.");
  const supabase = await createClient();
  const { error } = await supabase.from("expenses").update({ status: "void", void_reason: reason }).eq("id", id);
  if (error) throw new Error(error.message);
  revalidatePath(`/expenses/${id}`);
  revalidatePath("/expenses");
}

// ---------------------------------------------------------------------------
// Receipt upload -- same pattern as uploadLoadDocument (loads/pod-actions.ts):
// caller's own authenticated client (real Storage RLS applies, not a
// service-role bypass), private expense-documents bucket, polymorphic
// documents row (entity_type='expense').
// ---------------------------------------------------------------------------
const ALLOWED_TYPES = new Set(["application/pdf", "image/jpeg", "image/png"]);
const MAX_BYTES = 15 * 1024 * 1024;
const RECEIPT_DOCUMENT_TYPES = new Set([
  "expense_receipt",
  "fuel_receipt",
  "toll_receipt",
  "lumper_receipt",
  "scale_ticket",
  "repair_invoice",
  "other",
]);

export async function uploadExpenseReceipt(expenseId: string, documentType: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  if (!RECEIPT_DOCUMENT_TYPES.has(documentType)) throw new Error(`Unsupported document type: ${documentType}`);
  const file = formData.get("file");
  if (!(file instanceof File)) throw new Error("No file provided.");
  if (file.size > MAX_BYTES) throw new Error("File is too large (15 MB max).");
  if (!ALLOWED_TYPES.has(file.type)) throw new Error("Unsupported file type. Use PDF, JPG, or PNG.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: expense } = await supabase.from("expenses").select("id, receipt_document_id").eq("id", expenseId).single();
  if (!expense) throw new Error("Expense not found.");

  const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-100);
  const storagePath = `${organizationId}/${expenseId}/${Date.now()}_${safeName}`;

  const { error: uploadError } = await supabase.storage
    .from("expense-documents")
    .upload(storagePath, file, { contentType: file.type, upsert: false });
  if (uploadError) throw new Error(uploadError.message);

  const { data: doc, error: insertError } = await supabase
    .from("documents")
    .insert({
      organization_id: organizationId,
      entity_type: "expense",
      entity_id: expenseId,
      document_type: documentType,
      file_name: file.name,
      file_path: storagePath,
      file_size_bytes: file.size,
      mime_type: file.type,
      uploaded_by: user?.id ?? null,
    })
    .select("id")
    .single();
  if (insertError) throw new Error(insertError.message);

  const { error: linkError } = await supabase.from("expenses").update({ receipt_document_id: doc.id }).eq("id", expenseId);
  if (linkError) throw new Error(linkError.message);

  revalidatePath(`/expenses/${expenseId}`);
}

// Phase 2G.9 (item 10): same gap class as getPodSignedUrl -- no role check.
export async function getExpenseReceiptSignedUrl(storagePath: string, download: boolean): Promise<string> {
  await requireRole(FINANCIAL_ROLES);
  const supabase = await createClient();
  const { data, error } = await supabase.storage
    .from("expense-documents")
    .createSignedUrl(storagePath, 300, download ? { download: true } : undefined);
  if (error || !data) throw new Error(error?.message ?? "Could not generate a download link.");
  return data.signedUrl;
}
