"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";

function revalidateInvoiceViews(invoiceId: string) {
  revalidatePath(`/invoices/${invoiceId}`);
  revalidatePath("/collections");
  revalidatePath("/dashboard");
}

// ---------------------------------------------------------------------------
// Collection activity (contact log / notes). Append-only -- there is no
// update/delete action for this table at all, matching the RLS policies
// (0027_collections.sql) which grant insert/select only.
// ---------------------------------------------------------------------------
export async function logContact(invoiceId: string, formData: FormData) {
  const note = String(formData.get("note") || "").trim();
  if (!note) redirect(`/invoices/${invoiceId}?error=${encodeURIComponent("A note is required to log contact.")}`);

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const nextFollowUp = emptyToNull(formData.get("next_follow_up_at"));

  const { error } = await supabase.from("invoice_collection_activity").insert({
    organization_id: organizationId,
    invoice_id: invoiceId,
    contact_method: String(formData.get("contact_method") || "other"),
    contact_name: emptyToNull(formData.get("contact_name")),
    note,
    next_follow_up_at: nextFollowUp ? new Date(nextFollowUp).toISOString() : null,
    created_by: user?.id ?? null,
  });
  if (error) redirect(`/invoices/${invoiceId}?error=${encodeURIComponent(error.message)}`);

  // Auto-advance not_started -> contacted, exactly once, never overriding
  // a status a collector has already moved further along (e.g. follow_up,
  // escalated) or resolved/disputed.
  await supabase.from("invoices").update({ collection_status: "contacted" }).eq("id", invoiceId).eq("collection_status", "not_started");

  await supabase.rpc("log_activity", { p_entity_type: "invoice", p_entity_id: invoiceId, p_action: "collection_contact_logged" });
  revalidateInvoiceViews(invoiceId);
  redirect(`/invoices/${invoiceId}`);
}

// ---------------------------------------------------------------------------
// Promise to Pay. promised_amount/promise_date/expected_payment_date are
// never edited in place after creation -- cancelPromise() (below) is the
// only mutation, matching "avoid silently overwriting collection history".
// ---------------------------------------------------------------------------
export async function createPromise(invoiceId: string, formData: FormData) {
  const promisedAmount = toNumber(formData.get("promised_amount"));
  const expectedDate = String(formData.get("expected_payment_date") || "");
  if (!promisedAmount || promisedAmount <= 0) {
    redirect(`/invoices/${invoiceId}?error=${encodeURIComponent("Enter a promised amount greater than zero.")}`);
  }
  if (!expectedDate) {
    redirect(`/invoices/${invoiceId}?error=${encodeURIComponent("Expected payment date is required.")}`);
  }

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { error } = await supabase.from("payment_promises").insert({
    organization_id: organizationId,
    invoice_id: invoiceId,
    promised_amount: promisedAmount,
    expected_payment_date: expectedDate,
    contact_person: emptyToNull(formData.get("contact_person")),
    notes: emptyToNull(formData.get("notes")),
    created_by: user?.id ?? null,
  });
  if (error) redirect(`/invoices/${invoiceId}?error=${encodeURIComponent(error.message)}`);

  await supabase.from("invoices").update({ collection_status: "promise_to_pay" }).eq("id", invoiceId);
  await supabase.rpc("log_activity", { p_entity_type: "invoice", p_entity_id: invoiceId, p_action: "promise_to_pay_created" });
  revalidateInvoiceViews(invoiceId);
  redirect(`/invoices/${invoiceId}`);
}

export async function cancelPromise(promiseId: string, invoiceId: string, formData: FormData) {
  const reason = String(formData.get("cancelled_reason") || "").trim();
  if (!reason) redirect(`/invoices/${invoiceId}?error=${encodeURIComponent("A reason is required to cancel a promise.")}`);

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { error } = await supabase
    .from("payment_promises")
    .update({ status: "cancelled", cancelled_by: user?.id ?? null, cancelled_at: new Date().toISOString(), cancelled_reason: reason })
    .eq("id", promiseId)
    .eq("status", "open");
  if (error) redirect(`/invoices/${invoiceId}?error=${encodeURIComponent(error.message)}`);

  revalidateInvoiceViews(invoiceId);
  redirect(`/invoices/${invoiceId}`);
}

// ---------------------------------------------------------------------------
// Disputes. Resolution updates the same row (status/resolved_at/resolved_by
// /resolution) rather than deleting it -- the dispute's full history stays.
// ---------------------------------------------------------------------------
export async function openDispute(invoiceId: string, formData: FormData) {
  const disputedAmount = toNumber(formData.get("disputed_amount"));
  if (!disputedAmount || disputedAmount <= 0) {
    redirect(`/invoices/${invoiceId}?error=${encodeURIComponent("Enter a disputed amount greater than zero.")}`);
  }

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { error } = await supabase.from("invoice_disputes").insert({
    organization_id: organizationId,
    invoice_id: invoiceId,
    reason: String(formData.get("reason") || "other"),
    disputed_amount: disputedAmount,
    broker_contact: emptyToNull(formData.get("broker_contact")),
    notes: emptyToNull(formData.get("notes")),
    opened_by: user?.id ?? null,
  });
  if (error) redirect(`/invoices/${invoiceId}?error=${encodeURIComponent(error.message)}`);

  await supabase.from("invoices").update({ collection_status: "disputed" }).eq("id", invoiceId);
  await supabase.rpc("log_activity", { p_entity_type: "invoice", p_entity_id: invoiceId, p_action: "dispute_opened" });
  revalidateInvoiceViews(invoiceId);
  redirect(`/invoices/${invoiceId}`);
}

export async function resolveDispute(disputeId: string, invoiceId: string, formData: FormData) {
  const outcome = String(formData.get("outcome") || "resolved"); // 'resolved' | 'rejected'
  const resolution = String(formData.get("resolution") || "").trim();
  if (!resolution) redirect(`/invoices/${invoiceId}?error=${encodeURIComponent("A resolution note is required.")}`);
  if (!["resolved", "rejected"].includes(outcome)) {
    redirect(`/invoices/${invoiceId}?error=${encodeURIComponent("Invalid dispute outcome.")}`);
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { error } = await supabase
    .from("invoice_disputes")
    .update({ status: outcome, resolution, resolved_by: user?.id ?? null, resolved_at: new Date().toISOString() })
    .eq("id", disputeId)
    .in("status", ["open", "under_review"]);
  if (error) redirect(`/invoices/${invoiceId}?error=${encodeURIComponent(error.message)}`);

  await supabase.rpc("log_activity", { p_entity_type: "invoice", p_entity_id: invoiceId, p_action: `dispute_${outcome}` });
  revalidateInvoiceViews(invoiceId);
  redirect(`/invoices/${invoiceId}`);
}

export async function markDisputeUnderReview(disputeId: string, invoiceId: string) {
  const supabase = await createClient();
  await supabase.from("invoice_disputes").update({ status: "under_review" }).eq("id", disputeId).eq("status", "open");
  revalidateInvoiceViews(invoiceId);
}

// ---------------------------------------------------------------------------
// Collector assignment. The org-membership check is enforced at the DB
// level too (guard_invoice_collector_assignment(), 0027) -- this dropdown
// is only ever populated with the current org's own profiles, but a
// cross-org id submitted directly would still be rejected by the trigger.
// ---------------------------------------------------------------------------
export async function assignCollector(invoiceId: string, formData: FormData) {
  const collectorId = emptyToNull(formData.get("assigned_collector_id"));
  const supabase = await createClient();
  const { error } = await supabase.from("invoices").update({ assigned_collector_id: collectorId }).eq("id", invoiceId);
  if (error) redirect(`/invoices/${invoiceId}?error=${encodeURIComponent(error.message)}`);
  revalidateInvoiceViews(invoiceId);
  redirect(`/invoices/${invoiceId}`);
}

// ---------------------------------------------------------------------------
// Manual collection-status override (e.g. escalate, or move back from
// resolved). Payment-triggered transitions (see apply_payment_to_invoice()
// in 0027) can still override this afterward on full payment -- that's the
// one case where the DB, not a collector, has the final say.
// ---------------------------------------------------------------------------
export async function updateCollectionStatus(invoiceId: string, formData: FormData) {
  const status = String(formData.get("collection_status") || "");
  const supabase = await createClient();
  const { error } = await supabase.from("invoices").update({ collection_status: status }).eq("id", invoiceId);
  if (error) redirect(`/invoices/${invoiceId}?error=${encodeURIComponent(error.message)}`);
  revalidateInvoiceViews(invoiceId);
  redirect(`/invoices/${invoiceId}`);
}

// ---------------------------------------------------------------------------
// Reminders. No email provider is configured anywhere in this project
// (same finding as billing-packet-actions.ts) -- this creates the pending
// row, attempts the real send, and records the actual outcome, exactly
// like sendBillingPacket()'s honest-failure pattern. Never marks 'sent'
// without a provider actually succeeding.
// ---------------------------------------------------------------------------
export async function queueReminder(invoiceId: string, formData: FormData) {
  const stage = String(formData.get("stage") || "");
  const recipientEmail = emptyToNull(formData.get("recipient_email"));
  const force = formData.get("force") === "1";

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!force) {
    const { data: existing } = await supabase
      .from("invoice_reminders")
      .select("id")
      .eq("invoice_id", invoiceId)
      .eq("stage", stage)
      .neq("status", "failed")
      .limit(1);
    if (existing && existing.length > 0) {
      redirect(
        `/invoices/${invoiceId}?error=${encodeURIComponent("A reminder for this stage was already sent/queued. Resend explicitly if you really want to send another.")}`
      );
    }
  }

  const { data: reminder, error: insertError } = await supabase
    .from("invoice_reminders")
    .insert({ organization_id: organizationId, invoice_id: invoiceId, stage, recipient_email: recipientEmail, created_by: user?.id ?? null })
    .select("id")
    .single();
  if (insertError || !reminder) redirect(`/invoices/${invoiceId}?error=${encodeURIComponent(insertError?.message ?? "Could not queue reminder.")}`);

  const sendResult = await sendReminderEmail();
  if (sendResult.ok) {
    await supabase.from("invoice_reminders").update({ status: "sent", sent_at: new Date().toISOString() }).eq("id", reminder.id);
  } else {
    await supabase.from("invoice_reminders").update({ status: "failed", error_message: sendResult.error }).eq("id", reminder.id);
  }

  revalidateInvoiceViews(invoiceId);
  redirect(`/invoices/${invoiceId}`);
}

// No email provider exists anywhere in this project (same finding as
// billing-packet-actions.ts's sendEmailWithAttachment) -- always fails
// clearly. Wiring a real provider later only requires implementing this.
async function sendReminderEmail(): Promise<{ ok: true } | { ok: false; error: string }> {
  return {
    ok: false,
    error: "Email reminders are not configured -- no email provider (e.g. Resend, SendGrid) is connected for this organization. Connect one in Settings → Integrations.",
  };
}
