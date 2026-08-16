"use server";

import { insertRecord, updateRecord } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";

function truckValues(formData: FormData) {
  return {
    carrier_id: String(formData.get("carrier_id")),
    unit_number: String(formData.get("unit_number")),
    vin: emptyToNull(formData.get("vin")),
    make: emptyToNull(formData.get("make")),
    model: emptyToNull(formData.get("model")),
    year: toNumber(formData.get("year")),
    license_plate: emptyToNull(formData.get("license_plate")),
    license_state: emptyToNull(formData.get("license_state")),
    ownership_type: emptyToNull(formData.get("ownership_type")),
    status: String(formData.get("status") || "active"),
    current_odometer: toNumber(formData.get("current_odometer")),
    registration_expiry_date: emptyToNull(formData.get("registration_expiry_date")),
    annual_inspection_expiry_date: emptyToNull(formData.get("annual_inspection_expiry_date")),
  };
}

export async function createTruck(formData: FormData) {
  await insertRecord("trucks", truckValues(formData), "/trucks");
}

export async function updateTruck(id: string, formData: FormData) {
  await updateRecord("trucks", id, truckValues(formData), "/trucks");
}
