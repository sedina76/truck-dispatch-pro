"use server";

import { insertRecord, updateRecord } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";

function trailerValues(formData: FormData) {
  return {
    carrier_id: emptyToNull(formData.get("carrier_id")),
    unit_number: String(formData.get("unit_number")),
    trailer_type: emptyToNull(formData.get("trailer_type")),
    length_ft: toNumber(formData.get("length_ft")),
    license_plate: emptyToNull(formData.get("license_plate")),
    license_state: emptyToNull(formData.get("license_state")),
    ownership_type: emptyToNull(formData.get("ownership_type")),
    status: String(formData.get("status") || "active"),
    registration_expiry_date: emptyToNull(formData.get("registration_expiry_date")),
    annual_inspection_expiry_date: emptyToNull(formData.get("annual_inspection_expiry_date")),
  };
}

export async function createTrailer(formData: FormData) {
  await insertRecord("trailers", trailerValues(formData), "/trailers");
}

export async function updateTrailer(id: string, formData: FormData) {
  await updateRecord("trailers", id, trailerValues(formData), "/trailers");
}
