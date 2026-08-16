"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";

// Record Payment. Overpayment/void-invoice/amount<=0 are all rejected by
// the DB itself (guard_payment_amount(), 0026_accounts_receivable.sql) --
// this validates the same things client-side first only so the error
// message is friendly, never as the actual authority. payment_number is
// never set here; it's generated concurrency-safely by the column default
// (public.generate_payment_number()), and amount_paid/status on the
// invoice are never touched here either -- apply_payment_to_invoice()
// rolls those up automatically once this insert commits.
export async function recordPayment(formData: FormData) {
  const invoiceId = String(formData.get("invoice_id") || "");
  const amount = toNumber(formData.get("amount"));
  const paymentDate = String(formData.get("payment_date") || "");

  if (!invoiceId) redirect(`/payments/new?error=${encodeURIComponent("Select an invoice.")}`);
  if (!amount || amount <= 0) {
    redirect(`/payments/new?invoice_id=${invoiceId}&error=${encodeURIComponent("Enter an amount greater than zero.")}`);
  }

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { error } = await supabase.from("payments").insert({
    organization_id: organizationId,
    invoice_id: invoiceId,
    amount,
    method: String(formData.get("method") || "ach"),
    received_at: paymentDate ? new Date(paymentDate).toISOString() : new Date().toISOString(),
    reference_number: emptyToNull(formData.get("reference_number")),
    check_number: emptyToNull(formData.get("check_number")),
    bank_reference: emptyToNull(formData.get("bank_reference")),
    notes: emptyToNull(formData.get("notes")),
    recorded_by: user?.id ?? null,
  });

  if (error) {
    // guard_payment_amount() raises a plain-text exception (overpayment,
    // void invoice, non-positive amount) -- surface it verbatim via a
    // query param since this is a plain <form action> with no client JS,
    // not a caught fetch() call.
    redirect(`/payments/new?invoice_id=${invoiceId}&error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath(`/invoices/${invoiceId}`);
  revalidatePath("/payments");
  revalidatePath("/accounts-receivable");
  redirect(`/invoices/${invoiceId}`);
}

// Void/reversal -- the only sanctioned correction for a posted payment.
// Never deletes the row: sets status='voided' + the audit fields, which
// re-fires apply_payment_to_invoice() (AFTER UPDATE on payments) and
// recomputes the invoice's amount_paid/status excluding this payment,
// exactly as if it had never counted -- while the row itself, and the
// original payment_number/amount/method/reference, remain on record
// forever for audit purposes.
export async function voidPayment(paymentId: string, invoiceId: string, formData: FormData) {
  const reason = String(formData.get("void_reason") || "").trim();
  if (!reason) {
    redirect(`/payments/${paymentId}?error=${encodeURIComponent("A reason is required to void a payment.")}`);
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { error } = await supabase
    .from("payments")
    .update({
      status: "voided",
      voided_by: user?.id ?? null,
      voided_at: new Date().toISOString(),
      void_reason: reason,
    })
    .eq("id", paymentId)
    .eq("status", "posted"); // idempotency guard: an already-voided payment can't be voided again

  if (error) {
    redirect(`/payments/${paymentId}?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath(`/invoices/${invoiceId}`);
  revalidatePath(`/payments/${paymentId}`);
  revalidatePath("/payments");
  revalidatePath("/accounts-receivable");
  redirect(`/invoices/${invoiceId}`);
}

// Notes are the only thing safely editable in place on a posted payment --
// amount/method/invoice/reference are immutable after creation (void +
// re-record is the correction path for those, per spec) so there is no
// generic updatePayment() anymore.
export async function updatePaymentNotes(paymentId: string, invoiceId: string, formData: FormData) {
  const supabase = await createClient();
  const { error } = await supabase
    .from("payments")
    .update({ notes: emptyToNull(formData.get("notes")) })
    .eq("id", paymentId);
  if (error) throw new Error(error.message);
  revalidatePath(`/payments/${paymentId}`);
  revalidatePath(`/invoices/${invoiceId}`);
}
