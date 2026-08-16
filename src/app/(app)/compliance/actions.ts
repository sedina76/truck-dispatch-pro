"use server";

import { insertRecord, updateRecord } from "@/lib/actions/records";
import { emptyToNull } from "@/lib/utils/form";

function complianceValues(formData: FormData) {
  return {
    entity_type: String(formData.get("entity_type")),
    entity_id: String(formData.get("entity_id")),
    item_type: String(formData.get("item_type")),
    expiry_date: emptyToNull(formData.get("expiry_date")),
    status: String(formData.get("status") || "valid"),
    notes: emptyToNull(formData.get("notes")),
  };
}

export async function createComplianceItem(formData: FormData) {
  await insertRecord("compliance_items", complianceValues(formData), "/compliance");
}

export async function updateComplianceItem(id: string, formData: FormData) {
  await updateRecord("compliance_items", id, complianceValues(formData), "/compliance");
}
