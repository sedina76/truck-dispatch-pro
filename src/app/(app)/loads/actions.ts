"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { requireOperationalAccess } from "@/lib/billing/operational-access";
import { emptyToNull, toNumber } from "@/lib/utils/form";

// Phase 2G.10 writer cutover: rate is written to load_financials, not
// loads, in the same action as the base-table write below -- see
// writeLoadFinancials(). rate_confirmation_number stays on loads (Phase
// 2G.9 reclassification: operational, not financial). detention_rate/
// layover_rate are not part of loadValues() at all -- confirmed by
// inspection (2G.9/2G.10 full search) that no form in this app has ever
// written them; they carry only their column default through every
// existing load, so there is nothing to cut over for those two fields.
// load_number is deliberately absent from this shape (0114: automatic
// organization-scoped load-number generation) -- it is never read from a
// form here. A client-supplied "load_number" field, if a stale request
// still sent one, is simply never looked at; loads.load_number is also
// immutable after creation at the database level
// (loads_guard_load_number_immutable), so updateLoad() below could never
// change it even if it tried to.
function loadValues(formData: FormData) {
  return {
    broker_id: emptyToNull(formData.get("broker_id")),
    customer_id: emptyToNull(formData.get("customer_id")),
    status: String(formData.get("status") || "draft"),
    commodity: emptyToNull(formData.get("commodity")),
    weight_lbs: toNumber(formData.get("weight_lbs")),
    equipment_type: emptyToNull(formData.get("equipment_type")),
    total_miles: toNumber(formData.get("total_miles")),
    rate_confirmation_number: emptyToNull(formData.get("rate_confirmation_number")),
    special_instructions: emptyToNull(formData.get("special_instructions")),
  };
}

// NOTE: requires 0067 applied (load_financials must exist) -- this
// function and every caller below are meant to ship in the SAME deploy as
// 0067/0068, never before. Upsert, not insert: on create, load_financials
// has no row yet for this load_id; on update, it already does (backfilled
// by 0067, or created by a prior call to this same function).
async function writeLoadFinancials(supabase: Awaited<ReturnType<typeof createClient>>, loadId: string, organizationId: string, formData: FormData) {
  const rate = toNumber(formData.get("rate")) ?? 0;
  const { error } = await supabase
    .from("load_financials")
    .upsert({ load_id: loadId, organization_id: organizationId, rate }, { onConflict: "load_id" });
  if (error) throw new Error(error.message);
}

// REMOVED (0114 hardening pass): this file used to also export a plain
// createLoad(), confirmed by search to have zero references anywhere in
// this codebase (the New Load form uses createLoadWithStops() in
// create-actions.ts exclusively). It allocated a load number and inserted
// the row as two separate PostgREST calls -- outside any single
// transaction, unlike create_load_with_stops() (allocation and insert in
// one PL/pgSQL function body) -- so a failed insert could strand an
// allocated number with no load ever created at it. Rather than carry
// that nontransactional shape forward (even dormant), it was deleted
// outright: no load-creation code path may allocate a number outside the
// transaction that creates the load, and this file had no live caller to
// preserve. If a plain (non-multi-stop) load-creation entry point is ever
// needed again, it should call create_load_with_stops() with a single
// stop, or a new dedicated SQL function following that same
// allocate-then-insert-in-one-transaction shape -- never a client-side
// two-call sequence.

// Bespoke rather than the generic updateRecord() helper: this needs to know
// whether the save just transitioned the load into 'delivered' (to route
// back to the load's own page and surface the auto-generated invoice)
// versus a routine edit (which keeps the existing redirect-to-list
// behavior every other entity in this app uses). The invoice itself is
// created by the auto_generate_invoice_from_delivered_load() trigger
// (0022_auto_invoice_on_delivery.sql) as part of the same update statement
// -- this action never creates the invoice itself, only detects that the
// trigger's condition was just met so it can route somewhere useful.
export async function updateLoad(id: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const { data: before } = await supabase.from("loads").select("status").eq("id", id).single();

  // Phase 2G.10: load_financials (rate) is written BEFORE the loads update
  // below -- if this same save also flips status to 'delivered' in the
  // same request, auto_generate_invoice_from_delivered_load() (0068) reads
  // load_financials.rate to seed the invoice, so the fresh rate must
  // already be committed by the time that trigger fires.
  await writeLoadFinancials(supabase, id, organizationId, formData);

  const values = loadValues(formData);
  const { error } = await supabase.from("loads").update(values).eq("id", id);
  if (error) throw new Error(error.message);

  await supabase.rpc("log_activity", { p_entity_type: "load", p_entity_id: id, p_action: "updated" });
  revalidatePath("/loads");
  revalidatePath(`/loads/${id}`);

  const justDelivered = before?.status !== "delivered" && values.status === "delivered";
  redirect(justDelivered ? `/loads/${id}?delivered=1` : "/loads");
}
