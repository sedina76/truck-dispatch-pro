"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { requireRole, BILLING_ROLES } from "@/lib/auth/require-role";
import { requireOperationalAccess } from "@/lib/billing/operational-access";
import { feePeriodError } from "@/lib/dispatch-fee-invoices/summary";

// Every write goes through the 0165 database functions (direct table
// writes are revoked): they check the role, the organization, the status
// and the amounts, so these actions only pass the form along and show the
// database's own message if it refuses.

const BASE = "/dispatch-fee-invoices";

function back(path: string, message: string): never {
  redirect(`${path}${path.includes("?") ? "&" : "?"}error=${encodeURIComponent(message)}`);
}

async function guard() {
  await requireRole(BILLING_ROLES);
  await requireOperationalAccess(); // SaaS paywall -- before any write.
  return createClient();
}

function text(formData: FormData, key: string): string {
  return String(formData.get(key) ?? "").trim();
}

export async function createDispatchFeeInvoice(formData: FormData) {
  const supabase = await guard();
  const carrierId = text(formData, "carrier_id");
  const start = text(formData, "period_start");
  const end = text(formData, "period_end");
  const retry = `${BASE}/new?carrier_id=${encodeURIComponent(carrierId)}&period_start=${encodeURIComponent(start)}&period_end=${encodeURIComponent(end)}`;
  if (!carrierId) back(retry, "Select a carrier.");
  const periodError = feePeriodError(start, end);
  if (periodError) back(retry, periodError);

  const { data, error } = await supabase.rpc("create_carrier_fee_invoice", {
    p_carrier_id: carrierId,
    p_period_start: start,
    p_period_end: end,
    p_notes: text(formData, "notes") || null,
  });
  if (error || !data) back(retry, error?.message ?? "Could not create the invoice.");

  revalidatePath(BASE);
  redirect(`${BASE}/${data as string}`);
}

export async function removeDispatchFeeInvoiceLine(invoiceId: string, lineId: string) {
  const supabase = await guard();
  const { error } = await supabase.rpc("remove_carrier_fee_invoice_line", { p_line_id: lineId });
  if (error) back(`${BASE}/${invoiceId}`, error.message);
  revalidatePath(`${BASE}/${invoiceId}`);
  revalidatePath(BASE);
}

export async function sendDispatchFeeInvoice(invoiceId: string) {
  const supabase = await guard();
  const { error } = await supabase.rpc("send_carrier_fee_invoice", { p_invoice_id: invoiceId });
  if (error) back(`${BASE}/${invoiceId}`, error.message);
  revalidatePath(`${BASE}/${invoiceId}`);
  revalidatePath(BASE);
}

export async function voidDispatchFeeInvoice(invoiceId: string, formData: FormData) {
  const supabase = await guard();
  const reason = text(formData, "void_reason");
  if (!reason) back(`${BASE}/${invoiceId}`, "A reason is required to void an invoice.");
  const { error } = await supabase.rpc("void_carrier_fee_invoice", { p_invoice_id: invoiceId, p_reason: reason });
  if (error) back(`${BASE}/${invoiceId}`, error.message);
  revalidatePath(`${BASE}/${invoiceId}`);
  revalidatePath(BASE);
}

const METHODS = new Set(["ach", "wire", "check", "credit_card", "cash", "other"]);

export async function recordDispatchFeeInvoicePayment(invoiceId: string, formData: FormData) {
  const supabase = await guard();
  const here = `${BASE}/${invoiceId}`;
  const amount = Number(text(formData, "amount"));
  if (!Number.isFinite(amount) || amount <= 0) back(here, "Enter a payment amount greater than zero.");
  const method = text(formData, "method") || "ach";
  if (!METHODS.has(method)) back(here, "Choose a payment method.");
  const paidDate = text(formData, "paid_date");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(paidDate)) back(here, "Enter the payment date.");

  const { error } = await supabase.rpc("record_carrier_fee_invoice_payment", {
    p_invoice_id: invoiceId,
    p_amount: Math.round(amount * 100) / 100,
    p_method: method,
    p_paid_date: paidDate,
    p_reference: text(formData, "reference_number") || null,
    p_notes: text(formData, "notes") || null,
  });
  if (error) back(here, error.message);
  revalidatePath(here);
  revalidatePath(BASE);
}

export async function voidDispatchFeeInvoicePayment(invoiceId: string, paymentId: string, formData: FormData) {
  const supabase = await guard();
  const reason = text(formData, "void_reason");
  if (!reason) back(`${BASE}/${invoiceId}`, "A reason is required to void a payment.");
  const { error } = await supabase.rpc("void_carrier_fee_invoice_payment", { p_payment_id: paymentId, p_reason: reason });
  if (error) back(`${BASE}/${invoiceId}`, error.message);
  revalidatePath(`${BASE}/${invoiceId}`);
  revalidatePath(BASE);
}
