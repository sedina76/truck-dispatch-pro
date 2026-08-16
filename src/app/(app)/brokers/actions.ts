"use server";

import { insertRecord, updateRecord } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";

function brokerValues(formData: FormData) {
  return {
    company_name: String(formData.get("company_name")),
    mc_number: emptyToNull(formData.get("mc_number")),
    contact_name: emptyToNull(formData.get("contact_name")),
    phone: emptyToNull(formData.get("phone")),
    email: emptyToNull(formData.get("email")),
    city: emptyToNull(formData.get("city")),
    state: emptyToNull(formData.get("state")),
    payment_terms_days: toNumber(formData.get("payment_terms_days")) ?? 30,
    is_blacklisted: formData.get("is_blacklisted") === "on",
    notes: emptyToNull(formData.get("notes")),
  };
}

export async function createBroker(formData: FormData) {
  await insertRecord("brokers", brokerValues(formData), "/brokers");
}

export async function updateBroker(id: string, formData: FormData) {
  await updateRecord("brokers", id, brokerValues(formData), "/brokers");
}
