"use server";

import { insertRecord } from "@/lib/actions/records";
import { emptyToNull } from "@/lib/utils/form";

export async function createDotViolation(formData: FormData) {
  await insertRecord(
    "dot_violations",
    {
      carrier_id: emptyToNull(formData.get("carrier_id")),
      driver_id: emptyToNull(formData.get("driver_id")),
      violation_date: emptyToNull(formData.get("violation_date")) ?? new Date().toISOString().slice(0, 10),
      violation_type: String(formData.get("violation_type")),
      description: emptyToNull(formData.get("description")),
      severity: String(formData.get("severity") || "medium"),
    },
    "/compliance/dot"
  );
}
