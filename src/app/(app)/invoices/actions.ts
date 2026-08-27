"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";
import { INVOICEABLE_LOAD_STATUSES } from "@/lib/billing/party";

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
//
// Invoice eligibility + duplicate-invoice repair: everything about the
// load -- whether it exists in THIS organization, whether it's actually
// ready to invoice, whether it already has one, its real rate, AND its
// real billing party -- is now re-derived here from a fresh server-side
// read. The load selector on /invoices/new already only offers eligible
// loads, but this function must never trust that a request actually came
// from that UI: a forged load_id/rate/broker_id/customer_id submitted
// directly must fail exactly the same way. "Not found" and "belongs to
// another organization" are deliberately indistinguishable in the
// load-eligibility error, so a forged request can never learn whether a
// given load id exists elsewhere.
//
// Party-integrity repair (follow-up audit): a same-organization
// broker_id/customer_id is not enough -- it must also be the SAME party
// already assigned to the selected load. public.loads.broker_id/
// customer_id are the schema's own authoritative billing-party fields:
// auto_generate_invoice_from_delivered_load() (0022/0028) copies them onto
// the invoice verbatim (never lets the trigger's own broker-wins-over-
// customer bill-to-display precedence substitute a different id), and
// nothing else in this schema treats "the invoice's party" as a separately
// choosable concept once a load is linked. This function now matches that
// exactly: broker_id/customer_id are DERIVED from the load, never read
// from the submitted form at all, once a load is selected.
export async function createInvoice(formData: FormData) {
  const values = invoiceValues(formData);
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  let loadNumber: string | null = null;
  let authoritativeRate: number | null = null;
  // Overridden below from the load's own row when a load is selected --
  // the submitted values.broker_id/values.customer_id are never used for a
  // load-linked invoice (see header comment).
  let resolvedBrokerId = values.broker_id;
  let resolvedCustomerId = values.customer_id;

  if (values.load_id) {
    const { data: load } = await supabase
      .from("loads")
      .select("id, load_number, status, broker_id, customer_id")
      .eq("id", values.load_id)
      .eq("organization_id", organizationId)
      .maybeSingle();
    const eligibleStatuses: readonly string[] = INVOICEABLE_LOAD_STATUSES;
    if (!load || !eligibleStatuses.includes(load.status)) {
      throw new Error("This load is not ready to invoice.");
    }

    // load_id is now confirmed to be this organization's own load, so this
    // existence check cannot leak a foreign invoice's presence -- it can
    // only ever match a same-org row (RLS on invoices already guarantees
    // that regardless). Any existing invoice -- including a voided one --
    // occupies this load's slot; see invoices_load_id_unique_idx (0022).
    const { data: existingInvoice } = await supabase.from("invoices").select("id").eq("load_id", values.load_id).maybeSingle();
    if (existingInvoice) throw new Error("An invoice already exists for this load.");

    // Authoritative rate (Section F): load_financials is the one writer-
    // cutover-confirmed source (2G.12) -- never the client-submitted `rate`
    // field, which this form no longer even submits (see the disabled
    // Rate input on the New Invoice page) but which a forged request could
    // still attempt to set.
    const { data: loadFinancials } = await supabase.from("load_financials").select("rate").eq("load_id", values.load_id).maybeSingle();
    loadNumber = load.load_number;
    authoritativeRate = Number(loadFinancials?.rate ?? 0);

    // Authoritative party (this audit's finding): whatever the submitted
    // form contained for broker_id/customer_id is discarded entirely in
    // favor of the load's own values -- including both-null, if the load
    // has no billing party on file yet (the page's own UI already warns
    // "select one below" for that case, but a load-linked invoice created
    // with no party still leaves bill_to_name freely editable, matching
    // existing behavior).
    resolvedBrokerId = load.broker_id;
    resolvedCustomerId = load.customer_id;
  } else {
    // Manual entry (no load_id): there is no load to derive a party from,
    // so the submitted broker_id/customer_id are what the user actually
    // chose from this organization's own dropdowns -- still re-verified
    // for ownership below, exactly as before this audit.
    if (values.broker_id) {
      const { data: broker } = await supabase.from("brokers").select("id").eq("id", values.broker_id).eq("organization_id", organizationId).maybeSingle();
      if (!broker) throw new Error("Selected broker is not available.");
    }
    if (values.customer_id) {
      const { data: customer } = await supabase.from("customers").select("id").eq("id", values.customer_id).eq("organization_id", organizationId).maybeSingle();
      if (!customer) throw new Error("Selected customer is not available.");
    }
  }

  const { data, error } = await supabase
    .from("invoices")
    .insert({ ...values, broker_id: resolvedBrokerId, customer_id: resolvedCustomerId, organization_id: organizationId })
    .select("id")
    .single();
  if (error) {
    // Concurrency backstop: two simultaneous createInvoice() calls for the
    // same load can both pass the existingInvoice check above (there is no
    // advisory lock here) -- invoices_load_id_unique_idx (0022) is what
    // actually guarantees only one of the two INSERTs can ever succeed.
    // The loser hits a 23505 unique-violation, translated to the same
    // friendly message rather than a raw Postgres error.
    if (error.code === "23505") throw new Error("An invoice already exists for this load.");
    throw new Error(error.message);
  }

  if (values.load_id && authoritativeRate) {
    await supabase.from("invoice_line_items").insert({
      organization_id: organizationId,
      invoice_id: data.id,
      description: `Freight charges -- Load ${loadNumber ?? ""}`.trim(),
      quantity: 1,
      unit_price: authoritativeRate,
      sort_order: 0,
    });
  }

  await supabase.rpc("log_activity", { p_entity_type: "invoice", p_entity_id: data.id, p_action: "created" });
  revalidatePath("/invoices");
  if (values.load_id) revalidatePath(`/loads/${values.load_id}`);
  redirect("/invoices");
}

// Phase A1 repair -- root cause: invoiceValues() has always included
// load_id (and broker_id/customer_id) straight from the submitted form,
// but invoices/[id]/page.tsx's edit form has never rendered a load_id
// field at all (not even a hidden input) -- formData.get("load_id") was
// therefore always null, and the generic updateRecord() helper (a plain
// .update(values)) wrote that null verbatim on EVERY edit of EVERY
// invoice, silently unlinking any load-linked invoice from its load on
// the very next save. No longer uses updateRecord() at all: load_id is
// now preserved purely from the invoice's own current database row, never
// from anything the client sends -- not even a hidden input, per explicit
// instruction, since a hidden input is still a client-controlled value a
// forged request can override. Confirmed before writing this: no
// workflow anywhere in this codebase ever legitimately changes an
// invoice's load_id after creation, so this makes it fully immutable
// post-creation at the application layer (migration 0112, unapplied,
// adds the same rule as the database-level backstop).
export async function updateInvoice(id: string, formData: FormData) {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  const { data: current } = await supabase.from("invoices").select("id, load_id").eq("id", id).maybeSingle();
  if (!current) throw new Error("Invoice not found.");

  const values = invoiceValues(formData);

  // Explicit rejection, not silent discard, for a DETECTABLE relink/link
  // attempt: the current UI never submits load_id at all, so this only
  // fires for a forged request naming a specific different (or newly
  // added) load id. An explicitly-emptied field is indistinguishable from
  // an omitted one at the FormData layer (both become null via
  // emptyToNull()) -- that case is still safely neutralized below by
  // never using values.load_id in the actual update, just not
  // individually surfaced as an error.
  if (values.load_id !== null && values.load_id !== current.load_id) {
    throw new Error("This invoice's linked load cannot be changed.");
  }

  let resolvedBrokerId = values.broker_id;
  let resolvedCustomerId = values.customer_id;

  if (current.load_id) {
    // Load-linked invoice: broker_id/customer_id are re-derived from the
    // load's own current row on every save, exactly like createInvoice()
    // does at creation -- never taken from the submitted form, so the
    // edit page's still-independent Broker/Customer selects can never
    // re-party a load-linked invoice, even before migration 0112 (the
    // database-level version of this same rule) is applied.
    const { data: load } = await supabase.from("loads").select("broker_id, customer_id").eq("id", current.load_id).maybeSingle();
    resolvedBrokerId = load?.broker_id ?? null;
    resolvedCustomerId = load?.customer_id ?? null;
  } else if (values.broker_id || values.customer_id) {
    // Manual invoice (load_id confirmed null above, and staying null):
    // broker_id/customer_id remain freely editable, same as before this
    // repair -- re-verified for organization ownership on every save.
    if (values.broker_id) {
      const { data: broker } = await supabase.from("brokers").select("id").eq("id", values.broker_id).eq("organization_id", organizationId).maybeSingle();
      if (!broker) throw new Error("Selected broker is not available.");
    }
    if (values.customer_id) {
      const { data: customer } = await supabase.from("customers").select("id").eq("id", values.customer_id).eq("organization_id", organizationId).maybeSingle();
      if (!customer) throw new Error("Selected customer is not available.");
    }
  }

  const { error } = await supabase
    .from("invoices")
    .update({ ...values, load_id: current.load_id, broker_id: resolvedBrokerId, customer_id: resolvedCustomerId })
    .eq("id", id);
  if (error) throw new Error(error.message);

  await supabase.rpc("log_activity", { p_entity_type: "invoice", p_entity_id: id, p_action: "updated" });
  revalidatePath("/invoices");
  revalidatePath(`/invoices/${id}`);
  redirect("/invoices");
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
