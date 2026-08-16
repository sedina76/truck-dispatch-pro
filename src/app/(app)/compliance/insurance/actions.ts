"use server";

import { insertRecord, updateRecord } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";

function policyValues(formData: FormData) {
  return {
    carrier_id: emptyToNull(formData.get("carrier_id")),
    policy_type: String(formData.get("policy_type")),
    insurer_name: String(formData.get("insurer_name")),
    policy_number: emptyToNull(formData.get("policy_number")),
    coverage_amount: toNumber(formData.get("coverage_amount")),
    premium_amount: toNumber(formData.get("premium_amount")),
    effective_date: emptyToNull(formData.get("effective_date")),
    expiry_date: emptyToNull(formData.get("expiry_date")),
    notes: emptyToNull(formData.get("notes")),
  };
}

export async function createInsurancePolicy(formData: FormData) {
  await insertRecord("insurance_policies", policyValues(formData), "/compliance/insurance");
}

export async function updateInsurancePolicy(id: string, formData: FormData) {
  await updateRecord("insurance_policies", id, policyValues(formData), "/compliance/insurance");
}
