"use server";

import { insertRecord, updateRecord } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";

function customerValues(formData: FormData) {
  return {
    company_name: String(formData.get("company_name")),
    contact_name: emptyToNull(formData.get("contact_name")),
    phone: emptyToNull(formData.get("phone")),
    email: emptyToNull(formData.get("email")),
    city: emptyToNull(formData.get("city")),
    state: emptyToNull(formData.get("state")),
    payment_terms_days: toNumber(formData.get("payment_terms_days")) ?? 30,
    is_active: formData.get("is_active") === "on",
  };
}

export async function createCustomer(formData: FormData) {
  await insertRecord("customers", customerValues(formData), "/customers");
}

export async function updateCustomer(id: string, formData: FormData) {
  await updateRecord("customers", id, customerValues(formData), "/customers");
}
