"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";

// ---------------------------------------------------------------------------
// Driver Pay Rates
// ---------------------------------------------------------------------------
export async function addDriverPayRate(driverId: string, formData: FormData) {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const payMethod = String(formData.get("pay_method"));
  const values: Record<string, unknown> = {
    organization_id: organizationId,
    driver_id: driverId,
    pay_method: payMethod,
    effective_from: String(formData.get("effective_from") || new Date().toISOString().slice(0, 10)),
    notes: emptyToNull(formData.get("notes")),
    created_by: user?.id ?? null,
    percentage_rate: null,
    rate_per_mile: null,
    flat_rate: null,
  };
  if (payMethod === "percentage") values.percentage_rate = toNumber(formData.get("rate_value"));
  if (payMethod === "per_mile") values.rate_per_mile = toNumber(formData.get("rate_value"));
  if (payMethod === "flat_rate") values.flat_rate = toNumber(formData.get("rate_value"));

  const { error } = await supabase.from("driver_pay_rates").insert(values);
  if (error) throw new Error(error.message);

  revalidatePath(`/drivers/${driverId}`);
}

// ---------------------------------------------------------------------------
// Settlement creation / draft editing
// ---------------------------------------------------------------------------
export async function createDriverSettlement(formData: FormData) {
  const driverId = String(formData.get("driver_id") || "");
  const periodStart = String(formData.get("period_start") || "");
  const periodEnd = String(formData.get("period_end") || "");
  if (!driverId || !periodStart || !periodEnd) throw new Error("Select a driver and period.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: driver } = await supabase.from("drivers").select("carrier_id").eq("id", driverId).single();
  if (!driver) throw new Error("Driver not found.");

  const { data: settlement, error } = await supabase
    .from("driver_settlements")
    .insert({
      organization_id: organizationId,
      driver_id: driverId,
      carrier_id: driver.carrier_id,
      period_start: periodStart,
      period_end: periodEnd,
      created_by: user?.id ?? null,
    })
    .select("id")
    .single();
  if (error) throw new Error(error.message);

  // Auto-populate with every currently-eligible load for this driver/period
  // (spec section 15: "System automatically finds eligible delivered loads
  // ... that have NOT already been settled"). Each insert re-validates
  // duplicate-protection itself (guard_driver_settlement_item_duplicate).
  const { data: payable } = await supabase.rpc("get_payable_loads", {
    p_driver_id: driverId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
  });

  for (const row of payable ?? []) {
    await supabase.from("driver_settlement_items").insert({
      organization_id: organizationId,
      driver_settlement_id: settlement.id,
      load_id: row.load_id,
      dispatch_id: row.dispatch_id,
      load_number: row.load_number,
      delivery_date: row.delivery_date,
      miles: row.miles,
      load_rate: row.load_rate,
      pay_method: row.pay_method,
      pay_rate: row.pay_rate,
      gross_pay: row.gross_pay,
      created_by: user?.id ?? null,
    });
  }

  revalidatePath("/driver-settlements");
  redirect(`/driver-settlements/${settlement.id}`);
}

export async function addSettlementLoad(settlementId: string, driverId: string, formData: FormData) {
  const loadId = String(formData.get("load_id") || "");
  if (!loadId) throw new Error("Select a load.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: calcRaw } = await supabase.rpc("calculate_driver_load_pay", { p_driver_id: driverId, p_load_id: loadId }).single();
  const calc = calcRaw as {
    dispatch_id: string | null;
    load_number: string;
    delivery_date: string | null;
    miles: number | null;
    load_rate: number;
    pay_method: string | null;
    pay_rate: number | null;
    gross_pay: number | null;
  } | null;
  if (!calc || calc.gross_pay === null) throw new Error("Could not calculate pay for this load -- confirm the driver has an active pay rate as of the delivery date.");

  const { data: load } = await supabase.from("loads").select("load_number").eq("id", loadId).single();

  const { error } = await supabase.from("driver_settlement_items").insert({
    organization_id: organizationId,
    driver_settlement_id: settlementId,
    load_id: loadId,
    dispatch_id: calc.dispatch_id,
    load_number: load?.load_number ?? calc.load_number,
    delivery_date: calc.delivery_date,
    miles: calc.miles,
    load_rate: calc.load_rate,
    pay_method: calc.pay_method,
    pay_rate: calc.pay_rate,
    gross_pay: calc.gross_pay,
    created_by: user?.id ?? null,
  });
  if (error) throw new Error(error.message);

  revalidatePath(`/driver-settlements/${settlementId}`);
}

export async function removeSettlementLoad(settlementId: string, itemId: string) {
  const supabase = await createClient();
  const { error } = await supabase.from("driver_settlement_items").delete().eq("id", itemId);
  if (error) throw new Error(error.message);
  revalidatePath(`/driver-settlements/${settlementId}`);
}

export async function addSettlementAdjustment(settlementId: string, formData: FormData) {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const bucket = String(formData.get("bucket"));
  const amount = toNumber(formData.get("amount")) ?? 0;

  const { error } = await supabase.from("driver_settlement_adjustments").insert({
    organization_id: organizationId,
    driver_settlement_id: settlementId,
    bucket,
    category: String(formData.get("category") || ""),
    amount: bucket === "adjustment" ? amount : Math.abs(amount),
    description: emptyToNull(formData.get("description")),
    source_reference: emptyToNull(formData.get("source_reference")),
    effective_date: String(formData.get("effective_date") || new Date().toISOString().slice(0, 10)),
    created_by: user?.id ?? null,
  });
  if (error) throw new Error(error.message);

  revalidatePath(`/driver-settlements/${settlementId}`);
}

// Link an explicitly-authorized maintenance recovery to this driver's
// settlement (spec DRIVER RECOVERY / TEAM DRIVER REQUIREMENT: the driver
// is chosen by staff on the maintenance record itself -- responsible_
// driver_id, 0050 -- never inferred here from "who drove the truck").
// guard_maintenance_recovery (0050) rejects this if the maintenance record
// isn't marked for driver recovery, if this settlement already carries it,
// or if it would exceed the remaining recoverable balance -- the same
// server-side backstop the carrier-side link uses.
export async function linkMaintenanceRecovery(settlementId: string, driverId: string, formData: FormData) {
  const maintenanceId = String(formData.get("maintenance_id") || "");
  if (!maintenanceId) throw new Error("Select a maintenance record.");
  const amount = toNumber(formData.get("amount"));
  if (!amount || amount <= 0) throw new Error("Enter a valid recovery amount.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: record } = await supabase
    .from("maintenance_records")
    .select("id, service_type, responsible_driver_id, trucks(unit_number), trailers(unit_number)")
    .eq("id", maintenanceId)
    .single();
  if (!record) throw new Error("Maintenance record not found.");
  if (record.responsible_driver_id !== driverId) {
    throw new Error("This maintenance record is not assigned to this driver as the responsible party.");
  }
  const unit = (record as unknown as { trucks: { unit_number: string } | null }).trucks?.unit_number ?? (record as unknown as { trailers: { unit_number: string } | null }).trailers?.unit_number ?? "";

  const { error } = await supabase.from("driver_settlement_adjustments").insert({
    organization_id: organizationId,
    driver_settlement_id: settlementId,
    bucket: "deduction",
    category: "Maintenance Recovery",
    amount,
    description: `Maintenance -- ${record.service_type}${unit ? ` (${unit})` : ""}`,
    linked_maintenance_id: maintenanceId,
    created_by: user?.id ?? null,
  });
  if (error) {
    if (error.message.includes("uq_driver_settlement_adjustments_maintenance_per_settlement")) throw new Error("This repair is already included in this settlement.");
    throw new Error(error.message);
  }

  revalidatePath(`/driver-settlements/${settlementId}`);
  revalidatePath(`/maintenance/${maintenanceId}`);
}

// Link an explicitly-authorized fuel recovery to this driver's settlement
// (spec DRIVER RECOVERY / TEAM DRIVER: the driver is chosen by staff on
// the fuel log itself -- responsible_driver_id, 0051 -- never inferred
// from fuel_logs.driver_id, "who purchased fuel," or "who drove the
// truck"). guard_fuel_recovery (0051) rejects this if the fuel log isn't
// marked for driver recovery, if this settlement already carries it, or
// if it would exceed the remaining recoverable balance -- the same
// server-side backstop the carrier-side link uses.
export async function linkFuelRecovery(settlementId: string, driverId: string, formData: FormData) {
  const fuelLogId = String(formData.get("fuel_log_id") || "");
  if (!fuelLogId) throw new Error("Select a fuel purchase.");
  const amount = toNumber(formData.get("amount"));
  if (!amount || amount <= 0) throw new Error("Enter a valid recovery amount.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: log } = await supabase
    .from("fuel_logs")
    .select("id, gallons, station_name, responsible_driver_id, trucks(unit_number)")
    .eq("id", fuelLogId)
    .single();
  if (!log) throw new Error("Fuel log not found.");
  if (log.responsible_driver_id !== driverId) {
    throw new Error("This fuel log is not assigned to this driver as the responsible party.");
  }
  const unit = (log as unknown as { trucks: { unit_number: string } | null }).trucks?.unit_number ?? "";

  const { error } = await supabase.from("driver_settlement_adjustments").insert({
    organization_id: organizationId,
    driver_settlement_id: settlementId,
    bucket: "deduction",
    category: "Fuel Recovery",
    amount,
    description: `Fuel -- ${log.gallons} gal${unit ? ` (${unit})` : ""}${log.station_name ? ` -- ${log.station_name}` : ""}`,
    linked_fuel_log_id: fuelLogId,
    created_by: user?.id ?? null,
  });
  if (error) {
    if (error.message.includes("uq_driver_settlement_adjustments_fuel_per_settlement")) throw new Error("This fuel purchase is already included in this settlement.");
    throw new Error(error.message);
  }

  revalidatePath(`/driver-settlements/${settlementId}`);
  revalidatePath(`/fuel/${fuelLogId}`);
}

export async function removeSettlementAdjustment(settlementId: string, adjustmentId: string) {
  const supabase = await createClient();
  const { error } = await supabase.from("driver_settlement_adjustments").delete().eq("id", adjustmentId);
  if (error) throw new Error(error.message);
  revalidatePath(`/driver-settlements/${settlementId}`);
}

// ---------------------------------------------------------------------------
// Approval / Void
// ---------------------------------------------------------------------------
export async function approveDriverSettlement(settlementId: string) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("approve_driver_settlement", { p_settlement_id: settlementId });
  if (error) throw new Error(error.message);
  revalidatePath(`/driver-settlements/${settlementId}`);
  revalidatePath("/driver-settlements");
}

export async function voidDriverSettlement(settlementId: string, formData: FormData) {
  const reason = String(formData.get("void_reason") || "").trim();
  const supabase = await createClient();
  const { error } = await supabase.rpc("void_driver_settlement", { p_settlement_id: settlementId, p_reason: reason });
  if (error) throw new Error(error.message);
  revalidatePath(`/driver-settlements/${settlementId}`);
  revalidatePath("/driver-settlements");
}

// ---------------------------------------------------------------------------
// Driver settlement payments -- dedicated table, never public.payments
// (see 0031_driver_settlements.sql header for why). Overpayment/void/draft
// protection is authoritative in the DB trigger; this mirrors that
// client-side only for a friendlier error surface, same pattern as
// recordPayment() (src/app/(app)/payments/actions.ts).
// ---------------------------------------------------------------------------
export async function recordDriverSettlementPayment(settlementId: string, formData: FormData) {
  const amount = toNumber(formData.get("amount"));
  if (!amount || amount <= 0) throw new Error("Enter an amount greater than zero.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { error } = await supabase.from("driver_settlement_payments").insert({
    organization_id: organizationId,
    driver_settlement_id: settlementId,
    amount,
    method: String(formData.get("method") || "ach"),
    paid_date: String(formData.get("paid_date") || new Date().toISOString().slice(0, 10)),
    reference_number: emptyToNull(formData.get("reference_number")),
    check_number: emptyToNull(formData.get("check_number")),
    bank_reference: emptyToNull(formData.get("bank_reference")),
    notes: emptyToNull(formData.get("notes")),
    recorded_by: user?.id ?? null,
  });
  if (error) throw new Error(error.message);

  revalidatePath(`/driver-settlements/${settlementId}`);
  revalidatePath("/driver-settlements");
}

export async function voidDriverSettlementPayment(settlementId: string, paymentId: string, formData: FormData) {
  const reason = String(formData.get("void_reason") || "").trim();
  if (!reason) throw new Error("A reason is required to void a payment.");

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { error } = await supabase
    .from("driver_settlement_payments")
    .update({ status: "voided", voided_by: user?.id ?? null, voided_at: new Date().toISOString(), void_reason: reason })
    .eq("id", paymentId)
    .eq("status", "posted");
  if (error) throw new Error(error.message);

  revalidatePath(`/driver-settlements/${settlementId}`);
  revalidatePath("/driver-settlements");
}
