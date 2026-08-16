"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";
import { toFuelActionState, type FuelActionState } from "@/lib/fuel/errors";

// Every recovery-critical write here follows the same rule established for
// Maintenance (0050) -- server-side validation first, then let the real DB
// guard triggers (guard_fuel_log_org, guard_fuel_recovery, 0051) be the
// final word -- their errors are translated into plain language rather
// than ever surfaced raw (spec section 30 report requirements imply the
// same "no raw Postgres errors" bar as Maintenance).
function translateFuelError(error: { message: string; code?: string }): string {
  const msg = error.message;
  if (msg.includes("uq_settlement_line_items_fuel_per_settlement") || msg.includes("uq_driver_settlement_adjustments_fuel_per_settlement")) {
    return "This fuel purchase is already included in this settlement.";
  }
  if (msg.includes("Recovery amount cannot exceed")) return msg;
  if (msg.includes("not marked for Carrier Settlement recovery") || msg.includes("not marked for Driver Settlement recovery")) return msg;
  if (msg.includes("fuel_logs_recoverable_le_total")) return "Recoverable amount cannot exceed the fuel purchase total.";
  if (msg.includes("fuel_logs_driver_recovery_shape")) return "Select the driver responsible for this recovery.";
  if (msg.includes("must belong to the same organization")) return msg;
  if (msg.includes("does not belong to")) return msg;
  if (msg.includes("linked expense or settlement recovery and cannot be deleted")) return msg;
  if (msg.includes("truck (and its carrier) cannot be changed")) return msg;
  return "This action could not be completed. Please try again.";
}

const VALID_PAID_BY = ["dispatch_company", "carrier", "driver", "other"] as const;
const VALID_RECOVERY_TYPES = ["none", "carrier_settlement", "driver_settlement", "carrier_direct", "driver_direct"] as const;

function fuelLogValues(formData: FormData) {
  const truckId = String(formData.get("truck_id") || "");
  if (!truckId) throw new Error("Select a truck.");

  const paidBy = String(formData.get("paid_by") || "dispatch_company");
  if (!(VALID_PAID_BY as readonly string[]).includes(paidBy)) throw new Error("Invalid Paid By selection.");

  const recoveryType = String(formData.get("recovery_type") || "none");
  if (!(VALID_RECOVERY_TYPES as readonly string[]).includes(recoveryType)) throw new Error("Invalid Recovery selection.");

  const totalAmount = toNumber(formData.get("total_amount")) ?? 0;
  const recoverableAmount = recoveryType === "carrier_settlement" || recoveryType === "driver_settlement" ? (toNumber(formData.get("recoverable_amount")) ?? 0) : 0;
  if (recoverableAmount > totalAmount) throw new Error("Recoverable amount cannot exceed the fuel purchase total.");
  if (recoverableAmount < 0) throw new Error("Recoverable amount cannot be negative.");

  const responsibleDriverId = recoveryType === "driver_settlement" ? emptyToNull(formData.get("responsible_driver_id")) : null;
  if (recoveryType === "driver_settlement" && !responsibleDriverId) {
    throw new Error("Select the driver responsible for this recovery.");
  }

  return {
    truck_id: truckId,
    driver_id: emptyToNull(formData.get("driver_id")),
    gallons: toNumber(formData.get("gallons")) ?? 0,
    price_per_gallon: toNumber(formData.get("price_per_gallon")),
    total_amount: totalAmount,
    odometer_reading: toNumber(formData.get("odometer_reading")),
    state: emptyToNull(formData.get("state")),
    station_name: emptyToNull(formData.get("station_name")),
    purchased_at: emptyToNull(formData.get("purchased_at")) ?? new Date().toISOString(),
    paid_by: paidBy,
    recovery_type: recoveryType,
    recoverable_amount: recoverableAmount,
    responsible_driver_id: responsibleDriverId,
  };
}

export async function createFuelLog(formData: FormData): Promise<{ id: string }> {
  if (!String(formData.get("gallons") || "").trim()) throw new Error("Gallons is required.");
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const values = fuelLogValues(formData);

  const { data, error } = await supabase
    .from("fuel_logs")
    .insert({ organization_id: organizationId, ...values })
    .select("id")
    .single();
  if (error) throw new Error(translateFuelError(error));

  await supabase.rpc("log_activity", { p_entity_type: "fuel", p_entity_id: data.id, p_action: "created", p_changes: null, p_organization_id: organizationId });
  revalidatePath("/fuel");
  return { id: data.id };
}

// useActionState-compatible (spec "ERROR UX"): a business-rule rejection
// here (locked record, invalid recoverable amount, missing responsible
// driver) is normal application feedback, returned as a FuelActionState,
// never thrown into the route's error boundary. All the actual validation/
// locking logic below is unchanged -- only how a rejection gets back to
// the caller changed.
export async function updateFuelLog(id: string, _prevState: FuelActionState, formData: FormData): Promise<FuelActionState> {
  try {
    const supabase = await createClient();
    const organizationId = await getCurrentOrgId();

    const { data: existing } = await supabase.from("fuel_logs").select("expense_id, recovered_amount").eq("id", id).single();
    if (!existing) throw new Error("Fuel log not found.");

    const values = fuelLogValues(formData);

    // Once an expense has been created or any recovery has actually
    // happened, the payment/recovery decision is locked -- changing it out
    // from under an already-created expense or already-posted settlement
    // deduction would silently orphan real accounting records (same
    // IDEMPOTENCY / DOUBLE-COUNTING PROTECTION rule as Maintenance, 0050).
    // truck_id is ALSO frozen here -- not just the payment fields -- since
    // carrier_id is re-derived from the truck on every update
    // (guard_fuel_log_org, 0051): letting truck_id change after a real
    // expense/recovery exists would silently reassign that historical cost
    // to a different carrier out from under it (spec section 13 RECOVERY
    // SAFETY: "Do not silently rewrite historical recovered fuel to another
    // carrier"). guard_fuel_log_org also rejects this at the DB layer as a
    // second, defense-in-depth backstop -- this app-layer exclusion is what
    // keeps the UI's own "Save" from ever attempting it in the first place.
    if (existing.expense_id || Number(existing.recovered_amount) > 0) {
      const { error } = await supabase
        .from("fuel_logs")
        .update({
          driver_id: values.driver_id,
          gallons: values.gallons,
          price_per_gallon: values.price_per_gallon,
          odometer_reading: values.odometer_reading,
          state: values.state,
          station_name: values.station_name,
          purchased_at: values.purchased_at,
        })
        .eq("id", id);
      if (error) throw new Error(translateFuelError(error));
    } else {
      const { error } = await supabase.from("fuel_logs").update(values).eq("id", id);
      if (error) throw new Error(translateFuelError(error));
    }

    await supabase.rpc("log_activity", { p_entity_type: "fuel", p_entity_id: id, p_action: "updated", p_changes: null, p_organization_id: organizationId });
    revalidatePath("/fuel");
    revalidatePath(`/fuel/${id}`);
  } catch (err) {
    return toFuelActionState(err);
  }
  return { error: null };
}

export async function deleteFuelLog(id: string) {
  const supabase = await createClient();
  const { error } = await supabase.from("fuel_logs").delete().eq("id", id);
  if (error) throw new Error(translateFuelError(error));
  revalidatePath("/fuel");
}

// ---------------------------------------------------------------------------
// Case 1 (Company pays / Company responsible) + Case 2 (Company pays /
// Carrier or Driver responsible): exactly ONE expense either way -- the
// $700 fuel purchase is one real company cash outflow regardless of who
// ultimately bears it; recovery (below) is a separate concept (spec
// CORE ACCOUNTING RULE). Idempotent: the conditional update
// (.is("expense_id", null)) only succeeds once, so a double-click/retry
// can never create a second expense (spec section 25/TEST G). Reuses
// expenses.fuel_log_id (0040) -- built specifically for this, never
// populated by any code until now.
// useActionState-compatible -- same rule as updateFuelLog above: "already
// recorded" (a double-click/race) and "only company-paid fuel" are
// expected business rejections, returned as a FuelActionState rather than
// thrown. The idempotency guarantee itself (the conditional
// .is("expense_id", null) update + rollback) is unchanged.
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- required positionally by useActionState's (prevState, formData) signature; this action takes no form fields of its own.
export async function createFuelExpense(id: string, _prevState: FuelActionState, _formData: FormData): Promise<FuelActionState> {
  try {
    const supabase = await createClient();
    const organizationId = await getCurrentOrgId();

    const { data: log } = await supabase.from("fuel_logs").select("*").eq("id", id).single();
    if (!log) throw new Error("Fuel log not found.");
    if (log.expense_id) throw new Error("This fuel expense has already been recorded.");
    if (log.paid_by !== "dispatch_company") throw new Error("Only company-paid fuel creates a company expense.");

    const { data: expense, error: expenseError } = await supabase
      .from("expenses")
      .insert({
        organization_id: organizationId,
        scope: "truck",
        category: "fuel",
        truck_id: log.truck_id,
        driver_id: log.driver_id,
        carrier_id: log.carrier_id,
        fuel_log_id: log.id,
        amount: log.total_amount,
        expense_date: log.purchased_at.slice(0, 10),
        vendor_name: log.station_name,
        description: `Fuel -- ${log.gallons} gal${log.station_name ? ` -- ${log.station_name}` : ""}`,
        status: "approved",
      })
      .select("id")
      .single();
    if (expenseError) throw new Error(translateFuelError(expenseError));

    // Conditional on expense_id still being null -- the actual idempotency
    // guarantee. If this affects 0 rows (a concurrent request already won),
    // roll back the just-created expense rather than leave an orphan.
    const { data: linked, error: linkError } = await supabase
      .from("fuel_logs")
      .update({ expense_id: expense.id })
      .eq("id", id)
      .is("expense_id", null)
      .select("id");
    if (linkError || !linked || linked.length === 0) {
      await supabase.from("expenses").delete().eq("id", expense.id);
      throw new Error("This fuel expense has already been recorded.");
    }

    await supabase.rpc("log_activity", { p_entity_type: "fuel", p_entity_id: id, p_action: "expense_created", p_changes: { expense_id: expense.id }, p_organization_id: organizationId });
    await supabase.rpc("log_activity", { p_entity_type: "expense", p_entity_id: expense.id, p_action: "created", p_changes: null, p_organization_id: organizationId });

    revalidatePath("/fuel");
    revalidatePath(`/fuel/${id}`);
  } catch (err) {
    return toFuelActionState(err);
  }
  return { error: null };
}

// ---------------------------------------------------------------------------
// Documents -- reuses the polymorphic documents table + the EXISTING
// expense-documents private storage bucket/policies (0040), entity_type=
// 'fuel' (0051). No new document table, no new bucket, no new storage
// policy.
// ---------------------------------------------------------------------------
const FUEL_DOCUMENT_TYPES = new Set(["fuel_receipt", "expense_receipt", "other"]);
const ALLOWED_MIME_TYPES = new Set(["application/pdf", "image/jpeg", "image/png"]);
const MAX_BYTES = 15 * 1024 * 1024;

export async function uploadFuelDocument(fuelLogId: string, documentType: string, formData: FormData) {
  if (!FUEL_DOCUMENT_TYPES.has(documentType)) throw new Error(`Unsupported document type: ${documentType}`);
  const file = formData.get("file");
  if (!(file instanceof File)) throw new Error("No file provided.");
  if (file.size > MAX_BYTES) throw new Error("File is too large (15 MB max).");
  if (!ALLOWED_MIME_TYPES.has(file.type)) throw new Error("Unsupported file type. Use PDF, JPG, or PNG.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: log } = await supabase.from("fuel_logs").select("id").eq("id", fuelLogId).single();
  if (!log) throw new Error("Fuel log not found.");

  const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-100);
  const storagePath = `${organizationId}/${fuelLogId}/${Date.now()}_${safeName}`;

  const { error: uploadError } = await supabase.storage.from("expense-documents").upload(storagePath, file, { contentType: file.type, upsert: false });
  if (uploadError) throw new Error(uploadError.message);

  const { error: insertError } = await supabase.from("documents").insert({
    organization_id: organizationId,
    entity_type: "fuel",
    entity_id: fuelLogId,
    document_type: documentType,
    file_name: file.name,
    file_path: storagePath,
    file_size_bytes: file.size,
    mime_type: file.type,
    uploaded_by: user?.id ?? null,
  });
  if (insertError) throw new Error(insertError.message);

  await supabase.rpc("log_activity", { p_entity_type: "fuel", p_entity_id: fuelLogId, p_action: `${documentType}_uploaded`, p_changes: null, p_organization_id: organizationId });
  revalidatePath(`/fuel/${fuelLogId}`);
}

export async function getFuelDocumentSignedUrl(storagePath: string, download: boolean): Promise<string> {
  const supabase = await createClient();
  const { data, error } = await supabase.storage.from("expense-documents").createSignedUrl(storagePath, 300, download ? { download: true } : undefined);
  if (error || !data) throw new Error(error?.message ?? "Could not generate a document link.");
  return data.signedUrl;
}
