"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";

// Every recovery-critical write here follows the same rule established for
// dispatches/expenses in prior sessions: server-side validation first,
// then let the real DB guard triggers (guard_maintenance_org,
// guard_maintenance_recovery, 0050) be the final word -- their errors are
// translated into plain language rather than ever surfaced raw (spec
// ERROR HANDLING).
function translateMaintenanceError(error: { message: string; code?: string }): string {
  const msg = error.message;
  if (msg.includes("uq_settlement_line_items_maintenance_per_settlement") || msg.includes("uq_driver_settlement_adjustments_maintenance_per_settlement")) {
    return "This repair is already included in this settlement.";
  }
  if (msg.includes("Recovery amount cannot exceed")) return msg;
  if (msg.includes("not marked for Carrier Settlement recovery") || msg.includes("not marked for Driver Settlement recovery")) return msg;
  if (msg.includes("maintenance_records_recoverable_le_cost")) return "Recoverable amount cannot exceed the repair cost.";
  if (msg.includes("maintenance_records_driver_recovery_shape")) return "Select the driver responsible for this recovery.";
  if (msg.includes("maintenance_records_truck_or_trailer")) return "Select a truck or a trailer.";
  // guard_maintenance_org() (0050): truck and trailer resolve to two
  // different real carriers -- already plain-language from the trigger
  // itself (spec EQUIPMENT -> CARRIER AUTO-SELECTION: "reject the
  // combination ... show a clear mismatch warning"), pass through as-is.
  if (msg.includes("belong to different carriers")) return msg;
  if (msg.includes("must belong to the same organization")) return msg;
  if (msg.includes("does not belong to")) return msg;
  return "This action could not be completed. Please try again.";
}

const VALID_PAID_BY = ["dispatch_company", "carrier", "driver", "other"] as const;
const VALID_RECOVERY_TYPES = ["none", "carrier_settlement", "driver_settlement", "carrier_direct", "driver_direct"] as const;

function maintenanceValues(formData: FormData) {
  const truckId = emptyToNull(formData.get("truck_id"));
  const trailerId = emptyToNull(formData.get("trailer_id"));
  if (!truckId && !trailerId) throw new Error("Select a truck or a trailer.");

  const paidBy = String(formData.get("paid_by") || "dispatch_company");
  if (!(VALID_PAID_BY as readonly string[]).includes(paidBy)) throw new Error("Invalid Paid By selection.");

  const recoveryType = String(formData.get("recovery_type") || "none");
  if (!(VALID_RECOVERY_TYPES as readonly string[]).includes(recoveryType)) throw new Error("Invalid Recovery selection.");

  const cost = toNumber(formData.get("cost")) ?? 0;
  const recoverableAmount = recoveryType === "carrier_settlement" || recoveryType === "driver_settlement" ? (toNumber(formData.get("recoverable_amount")) ?? 0) : 0;
  if (recoverableAmount > cost) throw new Error("Recoverable amount cannot exceed the repair cost.");
  if (recoverableAmount < 0) throw new Error("Recoverable amount cannot be negative.");

  const responsibleDriverId = recoveryType === "driver_settlement" ? emptyToNull(formData.get("responsible_driver_id")) : null;
  if (recoveryType === "driver_settlement" && !responsibleDriverId) {
    throw new Error("Select the driver responsible for this recovery.");
  }

  return {
    truck_id: truckId,
    trailer_id: trailerId,
    service_type: String(formData.get("service_type") || "").trim(),
    description: emptyToNull(formData.get("description")),
    cost,
    odometer_reading: toNumber(formData.get("odometer_reading")),
    vendor_name: emptyToNull(formData.get("vendor_name")),
    service_date: emptyToNull(formData.get("service_date")),
    next_service_due_date: emptyToNull(formData.get("next_service_due_date")),
    next_service_due_odometer: toNumber(formData.get("next_service_due_odometer")),
    paid_by: paidBy,
    recovery_type: recoveryType,
    recoverable_amount: recoverableAmount,
    responsible_driver_id: responsibleDriverId,
  };
}

export async function createMaintenanceRecord(formData: FormData): Promise<{ id: string }> {
  if (!String(formData.get("service_type") || "").trim()) throw new Error("Service type is required.");
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const values = maintenanceValues(formData);

  const { data, error } = await supabase
    .from("maintenance_records")
    .insert({ organization_id: organizationId, status: "open", ...values })
    .select("id")
    .single();
  if (error) throw new Error(translateMaintenanceError(error));

  await supabase.rpc("log_activity", { p_entity_type: "maintenance", p_entity_id: data.id, p_action: "created", p_changes: null, p_organization_id: organizationId });
  revalidatePath("/maintenance");
  return { id: data.id };
}

export async function updateMaintenanceRecord(id: string, formData: FormData) {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  const { data: existing } = await supabase.from("maintenance_records").select("expense_id, recovered_amount").eq("id", id).single();
  if (!existing) throw new Error("Maintenance record not found.");

  const values = maintenanceValues(formData);

  // Once an expense has been created or any recovery has actually
  // happened, the payment/recovery decision is locked -- changing it out
  // from under an already-created expense or already-posted settlement
  // deduction would silently orphan real accounting records (spec
  // IDEMPOTENCY / DOUBLE-COUNTING PROTECTION).
  if (existing.expense_id || Number(existing.recovered_amount) > 0) {
    const { error } = await supabase
      .from("maintenance_records")
      .update({
        truck_id: values.truck_id,
        trailer_id: values.trailer_id,
        service_type: values.service_type,
        description: values.description,
        odometer_reading: values.odometer_reading,
        vendor_name: values.vendor_name,
        service_date: values.service_date,
        next_service_due_date: values.next_service_due_date,
        next_service_due_odometer: values.next_service_due_odometer,
      })
      .eq("id", id);
    if (error) throw new Error(translateMaintenanceError(error));
  } else {
    const { error } = await supabase.from("maintenance_records").update(values).eq("id", id);
    if (error) throw new Error(translateMaintenanceError(error));
  }

  await supabase.rpc("log_activity", { p_entity_type: "maintenance", p_entity_id: id, p_action: "updated", p_changes: null, p_organization_id: organizationId });
  revalidatePath("/maintenance");
  revalidatePath(`/maintenance/${id}`);
}

// ---------------------------------------------------------------------------
// Case 1 (Company pays / Company responsible) + Case 2 (Company pays /
// Carrier or Driver responsible): exactly ONE expense either way -- the
// $800 repair is one real company cash outflow regardless of who
// ultimately bears it; recovery (below) is a separate concept (spec
// CRITICAL BUSINESS REQUIREMENT). Idempotent: the conditional update
// (.is("expense_id", null)) only succeeds once, so a double-click/retry
// can never create a second expense (spec IDEMPOTENCY / TEST G).
// ---------------------------------------------------------------------------
export async function createMaintenanceExpense(id: string): Promise<{ expenseId: string }> {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  const { data: record } = await supabase.from("maintenance_records").select("*").eq("id", id).single();
  if (!record) throw new Error("Maintenance record not found.");
  if (record.expense_id) throw new Error("This maintenance expense has already been recorded.");
  if (record.paid_by !== "dispatch_company") throw new Error("Only company-paid maintenance creates a company expense.");

  // scope='truck' requires truck_id and forbids load_id (guard_expense_
  // scope, 0040) -- trailer-only maintenance has no matching equipment
  // scope value in this schema, so it falls back to 'general' (still
  // correctly excluded from load profitability, spec PROFITABILITY RULE)
  // while keeping trailer_id as pure traceability (that guard never
  // restricts trailer_id).
  const scope = record.truck_id ? "truck" : "general";

  const { data: expense, error: expenseError } = await supabase
    .from("expenses")
    .insert({
      organization_id: organizationId,
      scope,
      category: "maintenance",
      truck_id: record.truck_id,
      trailer_id: record.trailer_id,
      carrier_id: scope === "truck" ? record.carrier_id : null,
      amount: record.cost,
      expense_date: record.service_date,
      vendor_name: record.vendor_name,
      description: `${record.service_type}${record.vendor_name ? ` -- ${record.vendor_name}` : ""}`,
      status: "approved",
    })
    .select("id")
    .single();
  if (expenseError) throw new Error(translateMaintenanceError(expenseError));

  // Conditional on expense_id still being null -- the actual idempotency
  // guarantee. If this affects 0 rows (a concurrent request already won),
  // roll back the just-created expense rather than leave an orphan.
  const { data: linked, error: linkError } = await supabase
    .from("maintenance_records")
    .update({ expense_id: expense.id })
    .eq("id", id)
    .is("expense_id", null)
    .select("id");
  if (linkError || !linked || linked.length === 0) {
    await supabase.from("expenses").delete().eq("id", expense.id);
    throw new Error("This maintenance expense has already been recorded.");
  }

  await supabase.rpc("log_activity", { p_entity_type: "maintenance", p_entity_id: id, p_action: "expense_created", p_changes: { expense_id: expense.id }, p_organization_id: organizationId });
  await supabase.rpc("log_activity", { p_entity_type: "expense", p_entity_id: expense.id, p_action: "created", p_changes: null, p_organization_id: organizationId });

  revalidatePath("/maintenance");
  revalidatePath(`/maintenance/${id}`);
  return { expenseId: expense.id };
}

export async function setMaintenanceStatus(id: string, status: "open" | "completed" | "cancelled") {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const { error } = await supabase.from("maintenance_records").update({ status }).eq("id", id);
  if (error) throw new Error(translateMaintenanceError(error));
  await supabase.rpc("log_activity", { p_entity_type: "maintenance", p_entity_id: id, p_action: `status_${status}`, p_changes: null, p_organization_id: organizationId });
  revalidatePath("/maintenance");
  revalidatePath(`/maintenance/${id}`);
}

// ---------------------------------------------------------------------------
// EQUIPMENT AVAILABILITY -- reuses the existing equipment_status column
// (no new flag). Reactivation is blocked server-side (can_reactivate_
// equipment, 0050) while another OPEN maintenance record still references
// the same unit (spec OUT OF SERVICE / DISPATCH).
// ---------------------------------------------------------------------------
export async function setEquipmentStatusFromMaintenance(truckId: string | null, trailerId: string | null, targetStatus: string) {
  const supabase = await createClient();

  if (targetStatus === "active") {
    const { data: canReactivate } = await supabase.rpc("can_reactivate_equipment", { p_truck_id: truckId, p_trailer_id: trailerId });
    if (!canReactivate) {
      throw new Error("This unit still has another open maintenance record -- resolve or cancel it first before marking the equipment active again.");
    }
  }

  if (truckId) {
    const { error } = await supabase.from("trucks").update({ status: targetStatus }).eq("id", truckId);
    if (error) throw new Error(translateMaintenanceError(error));
  }
  if (trailerId) {
    const { error } = await supabase.from("trailers").update({ status: targetStatus }).eq("id", trailerId);
    if (error) throw new Error(translateMaintenanceError(error));
  }

  revalidatePath("/maintenance");
  revalidatePath("/trucks");
  revalidatePath("/trailers");
}

// ---------------------------------------------------------------------------
// Documents -- reuses the polymorphic documents table + load-documents-
// style private storage pattern verbatim (entity_type='maintenance', 0050).
// No new document table, no new bucket.
// ---------------------------------------------------------------------------
const MAINTENANCE_DOCUMENT_TYPES = new Set(["repair_invoice", "expense_receipt", "estimate", "inspection_report", "before_photo", "after_photo", "other"]);
const ALLOWED_MIME_TYPES = new Set(["application/pdf", "image/jpeg", "image/png"]);
const MAX_BYTES = 15 * 1024 * 1024;

export async function uploadMaintenanceDocument(maintenanceId: string, documentType: string, formData: FormData) {
  if (!MAINTENANCE_DOCUMENT_TYPES.has(documentType)) throw new Error(`Unsupported document type: ${documentType}`);
  const file = formData.get("file");
  if (!(file instanceof File)) throw new Error("No file provided.");
  if (file.size > MAX_BYTES) throw new Error("File is too large (15 MB max).");
  if (!ALLOWED_MIME_TYPES.has(file.type)) throw new Error("Unsupported file type. Use PDF, JPG, or PNG.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: record } = await supabase.from("maintenance_records").select("id").eq("id", maintenanceId).single();
  if (!record) throw new Error("Maintenance record not found.");

  const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-100);
  const storagePath = `${organizationId}/${maintenanceId}/${Date.now()}_${safeName}`;

  const { error: uploadError } = await supabase.storage.from("load-documents").upload(storagePath, file, { contentType: file.type, upsert: false });
  if (uploadError) throw new Error(uploadError.message);

  const { error: insertError } = await supabase.from("documents").insert({
    organization_id: organizationId,
    entity_type: "maintenance",
    entity_id: maintenanceId,
    document_type: documentType,
    file_name: file.name,
    file_path: storagePath,
    file_size_bytes: file.size,
    mime_type: file.type,
    uploaded_by: user?.id ?? null,
  });
  if (insertError) throw new Error(insertError.message);

  await supabase.rpc("log_activity", { p_entity_type: "maintenance", p_entity_id: maintenanceId, p_action: `${documentType}_uploaded`, p_changes: null, p_organization_id: organizationId });
  revalidatePath(`/maintenance/${maintenanceId}`);
}

export async function getMaintenanceDocumentSignedUrl(storagePath: string, download: boolean): Promise<string> {
  const supabase = await createClient();
  const { data, error } = await supabase.storage.from("load-documents").createSignedUrl(storagePath, 300, download ? { download: true } : undefined);
  if (error || !data) throw new Error(error?.message ?? "Could not generate a document link.");
  return data.signedUrl;
}
