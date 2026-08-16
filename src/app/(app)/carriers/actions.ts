"use server";

import { insertRecord, updateRecord } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";

function carrierValues(formData: FormData) {
  return {
    legal_name: String(formData.get("legal_name")),
    dba_name: emptyToNull(formData.get("dba_name")),
    mc_number: emptyToNull(formData.get("mc_number")),
    dot_number: emptyToNull(formData.get("dot_number")),
    contact_name: emptyToNull(formData.get("contact_name")),
    phone: emptyToNull(formData.get("phone")),
    email: emptyToNull(formData.get("email")),
    city: emptyToNull(formData.get("city")),
    state: emptyToNull(formData.get("state")),
    dispatch_fee_percentage: toNumber(formData.get("dispatch_fee_percentage")) ?? 10,
    payment_terms_days: toNumber(formData.get("payment_terms_days")) ?? 7,
  };
}

export async function createCarrier(formData: FormData) {
  await insertRecord("carriers", carrierValues(formData), "/carriers");
}

export async function updateCarrier(id: string, formData: FormData) {
  await updateRecord("carriers", id, carrierValues(formData), "/carriers");
}
