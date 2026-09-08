"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { requireOperationalAccess } from "@/lib/billing/operational-access";
import { emptyToNull, toNumber } from "@/lib/utils/form";

// ---------------------------------------------------------------------------
// Settlement creation (period-based, auto-populates eligible loads) --
// spec section 7/8. Reuses the existing settlements/settlement_line_items
// tables (0006, extended by 0033) -- not a competing table.
// ---------------------------------------------------------------------------
export async function createCarrierSettlement(formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const carrierId = String(formData.get("carrier_id") || "");
  const periodStart = String(formData.get("period_start") || "");
  const periodEnd = String(formData.get("period_end") || "");
  if (!carrierId || !periodStart || !periodEnd) throw new Error("Select a carrier and period.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  const { data: settlement, error } = await supabase
    .from("settlements")
    .insert({
      organization_id: organizationId,
      carrier_id: carrierId,
      status: "draft",
      period_start: periodStart,
      period_end: periodEnd,
    })
    .select("id")
    .single();
  if (error) throw new Error(error.message);

  const { data: payable } = await supabase.rpc("get_payable_carrier_loads", {
    p_carrier_id: carrierId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
  });

  for (const row of payable ?? []) {
    await supabase.from("settlement_line_items").insert({
      organization_id: organizationId,
      settlement_id: settlement.id,
      item_type: "load_pay",
      description: `Load ${row.load_number}`,
      amount: row.carrier_rate,
      load_id: row.load_id,
      dispatch_id: row.dispatch_id,
      load_number: row.load_number,
      delivery_date: row.delivery_date,
      miles: row.miles,
      customer_revenue: row.customer_revenue,
      carrier_rate: row.carrier_rate,
      pay_basis: "dispatch_fee_snapshot",
      pickup_city: row.pickup_city,
      pickup_state: row.pickup_state,
      delivery_city: row.delivery_city,
      delivery_state: row.delivery_state,
    });
  }

  await supabase.rpc("log_activity", { p_entity_type: "settlement", p_entity_id: settlement.id, p_action: "created", p_changes: null, p_organization_id: organizationId });

  revalidatePath("/settlements");
  redirect(`/settlements/${settlement.id}`);
}

export async function addSettlementLoad(settlementId: string, carrierId: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const loadId = String(formData.get("load_id") || "");
  if (!loadId) throw new Error("Select a load.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  const { data: calc } = await supabase
    .rpc("calculate_carrier_load_settlement", { p_carrier_id: carrierId, p_load_id: loadId })
    .single();
  const row = calc as {
    dispatch_id: string | null;
    load_number: string;
    delivery_date: string | null;
    miles: number | null;
    customer_revenue: number;
    carrier_rate: number;
    pickup_city: string | null;
    pickup_state: string | null;
    delivery_city: string | null;
    delivery_state: string | null;
  } | null;
  if (!row || row.carrier_rate === null) throw new Error("Could not determine carrier pay for this load -- confirm a dispatch exists for this carrier.");

  const { error } = await supabase.from("settlement_line_items").insert({
    organization_id: organizationId,
    settlement_id: settlementId,
    item_type: "load_pay",
    description: `Load ${row.load_number}`,
    amount: row.carrier_rate,
    load_id: loadId,
    dispatch_id: row.dispatch_id,
    load_number: row.load_number,
    delivery_date: row.delivery_date,
    miles: row.miles,
    customer_revenue: row.customer_revenue,
    carrier_rate: row.carrier_rate,
    pay_basis: "dispatch_fee_snapshot",
    pickup_city: row.pickup_city,
    pickup_state: row.pickup_state,
    delivery_city: row.delivery_city,
    delivery_state: row.delivery_state,
  });
  if (error) throw new Error(error.message);

  await supabase.rpc("log_activity", { p_entity_type: "settlement", p_entity_id: settlementId, p_action: "load_added", p_changes: { load_number: row.load_number }, p_organization_id: organizationId });

  revalidatePath(`/settlements/${settlementId}`);
}

export async function removeSettlementLineItem(settlementId: string, itemId: string) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const { data: removed, error } = await supabase.from("settlement_line_items").delete().eq("id", itemId).select("item_type, description, amount").maybeSingle();
  if (error) throw new Error(error.message);

  await supabase.rpc("log_activity", { p_entity_type: "settlement", p_entity_id: settlementId, p_action: "line_item_removed", p_changes: removed ? { item_type: removed.item_type, description: removed.description, amount: removed.amount } : null, p_organization_id: organizationId });

  revalidatePath(`/settlements/${settlementId}`);
}

export async function addSettlementAdjustment(settlementId: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  const itemType = String(formData.get("item_type"));
  const amount = toNumber(formData.get("amount")) ?? 0;
  const category = String(formData.get("category") || "");

  const { error } = await supabase.from("settlement_line_items").insert({
    organization_id: organizationId,
    settlement_id: settlementId,
    item_type: itemType,
    description: category,
    amount: itemType === "adjustment" ? amount : Math.abs(amount),
    linked_advance_id: emptyToNull(formData.get("linked_advance_id")),
  });
  if (error) throw new Error(error.message);

  await supabase.rpc("log_activity", { p_entity_type: "settlement", p_entity_id: settlementId, p_action: `${itemType}_added`, p_changes: { category, amount }, p_organization_id: organizationId });

  revalidatePath(`/settlements/${settlementId}`);
}

// Link an existing dispatch_advances row to this carrier settlement --
// spec section 12: reuse, never duplicate. Also adds the matching line
// item so it appears in the settlement's own ledger.
export async function linkCarrierAdvance(settlementId: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const advanceId = String(formData.get("advance_id") || "");
  if (!advanceId) throw new Error("Select an advance.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  const { data: advance } = await supabase.from("dispatch_advances").select("amount, description, expense_type").eq("id", advanceId).single();
  if (!advance) throw new Error("Advance not found.");

  const { error: updateError } = await supabase
    .from("dispatch_advances")
    .update({ status: "deducted", deducted_settlement_id: settlementId })
    .eq("id", advanceId);
  if (updateError) throw new Error(updateError.message);

  const { error } = await supabase.from("settlement_line_items").insert({
    organization_id: organizationId,
    settlement_id: settlementId,
    item_type: "advance",
    description: advance.description || advance.expense_type.replace(/_/g, " "),
    amount: advance.amount,
    linked_advance_id: advanceId,
  });
  if (error) throw new Error(error.message);

  await supabase.rpc("log_activity", { p_entity_type: "settlement", p_entity_id: settlementId, p_action: "advance_linked", p_changes: { advance_id: advanceId, amount: advance.amount }, p_organization_id: organizationId });

  revalidatePath(`/settlements/${settlementId}`);
}

// Link a pending maintenance recovery to this carrier settlement -- exact
// same pattern as linkCarrierAdvance above (one real deduction line item,
// linked back to its source record via linked_maintenance_id, 0050,
// mirroring linked_advance_id). guard_maintenance_recovery (0050) is the
// real enforcement point: it rejects this insert server-side if the
// record isn't marked for carrier recovery, if this settlement already
// has a deduction for it, or if the amount would exceed the remaining
// recoverable balance -- so double-recovery/double-counting can't happen
// even via a retried/duplicated request.
export async function linkMaintenanceRecovery(settlementId: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const maintenanceId = String(formData.get("maintenance_id") || "");
  if (!maintenanceId) throw new Error("Select a maintenance record.");
  const amount = toNumber(formData.get("amount"));
  if (!amount || amount <= 0) throw new Error("Enter a valid recovery amount.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  const { data: record } = await supabase.from("maintenance_records").select("id, service_type, truck_id, trailer_id, service_date, trucks(unit_number), trailers(unit_number)").eq("id", maintenanceId).single();
  if (!record) throw new Error("Maintenance record not found.");
  const unit = (record as unknown as { trucks: { unit_number: string } | null; trailers: { unit_number: string } | null }).trucks?.unit_number ?? (record as unknown as { trailers: { unit_number: string } | null }).trailers?.unit_number ?? "";

  const { error } = await supabase.from("settlement_line_items").insert({
    organization_id: organizationId,
    settlement_id: settlementId,
    item_type: "deduction",
    description: `Maintenance -- ${record.service_type}${unit ? ` (${unit})` : ""}`,
    amount,
    linked_maintenance_id: maintenanceId,
  });
  if (error) {
    if (error.message.includes("uq_settlement_line_items_maintenance_per_settlement")) throw new Error("This repair is already included in this settlement.");
    if (error.message.includes("Recovery amount cannot exceed")) throw new Error(error.message);
    if (error.message.includes("not marked for Carrier Settlement recovery")) throw new Error(error.message);
    throw new Error(error.message);
  }

  await supabase.rpc("log_activity", { p_entity_type: "settlement", p_entity_id: settlementId, p_action: "maintenance_recovery_added", p_changes: { maintenance_id: maintenanceId, amount }, p_organization_id: organizationId });

  revalidatePath(`/settlements/${settlementId}`);
  revalidatePath(`/maintenance/${maintenanceId}`);
}

// Link a pending fuel recovery to this carrier settlement -- exact same
// pattern as linkMaintenanceRecovery above (one real deduction line item,
// linked back to its source record via linked_fuel_log_id, 0051, mirroring
// linked_maintenance_id/linked_advance_id). guard_fuel_recovery (0051) is
// the real enforcement point: it rejects this insert server-side if the
// fuel log isn't marked for carrier recovery, if this settlement already
// has a deduction for it, or if the amount would exceed the remaining
// recoverable balance -- so double-recovery/double-counting can't happen
// even via a retried/duplicated request.
export async function linkFuelRecovery(settlementId: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const fuelLogId = String(formData.get("fuel_log_id") || "");
  if (!fuelLogId) throw new Error("Select a fuel purchase.");
  const amount = toNumber(formData.get("amount"));
  if (!amount || amount <= 0) throw new Error("Enter a valid recovery amount.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  const { data: log } = await supabase.from("fuel_logs").select("id, gallons, station_name, purchased_at, trucks(unit_number)").eq("id", fuelLogId).single();
  if (!log) throw new Error("Fuel log not found.");
  const unit = (log as unknown as { trucks: { unit_number: string } | null }).trucks?.unit_number ?? "";

  const { error } = await supabase.from("settlement_line_items").insert({
    organization_id: organizationId,
    settlement_id: settlementId,
    item_type: "deduction",
    description: `Fuel -- ${log.gallons} gal${unit ? ` (${unit})` : ""}${log.station_name ? ` -- ${log.station_name}` : ""}`,
    amount,
    linked_fuel_log_id: fuelLogId,
  });
  if (error) {
    if (error.message.includes("uq_settlement_line_items_fuel_per_settlement")) throw new Error("This fuel purchase is already included in this settlement.");
    if (error.message.includes("Recovery amount cannot exceed")) throw new Error(error.message);
    if (error.message.includes("not marked for Carrier Settlement recovery")) throw new Error(error.message);
    throw new Error(error.message);
  }

  await supabase.rpc("log_activity", { p_entity_type: "settlement", p_entity_id: settlementId, p_action: "fuel_recovery_added", p_changes: { fuel_log_id: fuelLogId, amount }, p_organization_id: organizationId });

  revalidatePath(`/settlements/${settlementId}`);
  revalidatePath(`/fuel/${fuelLogId}`);
}

// Quick Pay (spec section 14): explicit opt-in only, never automatic.
export async function setQuickPay(settlementId: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const enabled = formData.get("quick_pay_enabled") === "on";
  const rate = toNumber(formData.get("quick_pay_rate_percent"));

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const { error } = await supabase.rpc("apply_quick_pay", {
    p_settlement_id: settlementId,
    p_enabled: enabled,
    p_rate_percent: enabled ? rate : null,
  });
  if (error) throw new Error(error.message);

  await supabase.rpc("log_activity", { p_entity_type: "settlement", p_entity_id: settlementId, p_action: enabled ? "quick_pay_applied" : "quick_pay_removed", p_changes: enabled ? { rate_percent: rate } : null, p_organization_id: organizationId });

  revalidatePath(`/settlements/${settlementId}`);
}

export async function setSettlementPayee(settlementId: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const payeeType = String(formData.get("payee_type") || "carrier");
  const supabase = await createClient();
  const { error } = await supabase.from("settlements").update({ payee_type: payeeType }).eq("id", settlementId);
  if (error) throw new Error(error.message);
  revalidatePath(`/settlements/${settlementId}`);
}

// ---------------------------------------------------------------------------
// Approval / Void
// ---------------------------------------------------------------------------
export async function approveCarrierSettlement(settlementId: string) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const { error } = await supabase.rpc("approve_carrier_settlement", { p_settlement_id: settlementId });
  if (error) throw new Error(error.message);

  await supabase.rpc("log_activity", { p_entity_type: "settlement", p_entity_id: settlementId, p_action: "approved", p_changes: null, p_organization_id: organizationId });

  revalidatePath(`/settlements/${settlementId}`);
  revalidatePath("/settlements");
}

export async function voidCarrierSettlement(settlementId: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const reason = String(formData.get("void_reason") || "").trim();
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const { error } = await supabase.rpc("void_carrier_settlement", { p_settlement_id: settlementId, p_reason: reason });
  if (error) throw new Error(error.message);

  await supabase.rpc("log_activity", { p_entity_type: "settlement", p_entity_id: settlementId, p_action: "voided", p_changes: { reason }, p_organization_id: organizationId });

  revalidatePath(`/settlements/${settlementId}`);
  revalidatePath("/settlements");
}

// ---------------------------------------------------------------------------
// Carrier settlement payments -- dedicated table (see 0033 header comment
// for why not public.payments or public.driver_settlement_payments).
// ---------------------------------------------------------------------------
export async function recordCarrierSettlementPayment(settlementId: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const amount = toNumber(formData.get("amount"));
  if (!amount || amount <= 0) throw new Error("Enter an amount greater than zero.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: payment, error } = await supabase
    .from("carrier_settlement_payments")
    .insert({
      organization_id: organizationId,
      settlement_id: settlementId,
      amount,
      method: String(formData.get("method") || "ach"),
      paid_date: String(formData.get("paid_date") || new Date().toISOString().slice(0, 10)),
      reference_number: emptyToNull(formData.get("reference_number")),
      check_number: emptyToNull(formData.get("check_number")),
      bank_reference: emptyToNull(formData.get("bank_reference")),
      notes: emptyToNull(formData.get("notes")),
      recorded_by: user?.id ?? null,
    })
    .select("id, payment_number")
    .single();
  if (error) throw new Error(error.message);

  await supabase.rpc("log_activity", { p_entity_type: "settlement", p_entity_id: settlementId, p_action: "payment_posted", p_changes: { payment_number: payment.payment_number, amount }, p_organization_id: organizationId });

  revalidatePath(`/settlements/${settlementId}`);
  revalidatePath("/settlements");
}

export async function voidCarrierSettlementPayment(settlementId: string, paymentId: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const reason = String(formData.get("void_reason") || "").trim();
  if (!reason) throw new Error("A reason is required to void a payment.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: voided, error } = await supabase
    .from("carrier_settlement_payments")
    .update({ status: "voided", voided_by: user?.id ?? null, voided_at: new Date().toISOString(), void_reason: reason })
    .eq("id", paymentId)
    .eq("status", "posted")
    .select("payment_number, amount")
    .single();
  if (error) throw new Error(error.message);

  await supabase.rpc("log_activity", { p_entity_type: "settlement", p_entity_id: settlementId, p_action: "payment_voided", p_changes: { payment_number: voided?.payment_number, amount: voided?.amount, reason }, p_organization_id: organizationId });

  revalidatePath(`/settlements/${settlementId}`);
  revalidatePath("/settlements");
}
