import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { updateComplianceItem } from "../actions";

const ENTITY_TYPES = ["carrier", "driver", "truck", "trailer"];
const ITEM_TYPES = [
  "cdl_expiry", "medical_card_expiry", "insurance_expiry", "registration_expiry",
  "authority_expiry", "annual_inspection", "drug_test", "ifta_renewal", "other",
];

export default async function ComplianceDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: item } = await supabase.from("compliance_items").select("*").eq("id", id).single();
  if (!item) notFound();

  return (
    <FormCard
      title="Compliance Item"
      description="Requirement details. Changes save immediately."
      action={updateComplianceItem.bind(null, id)}
      cancelHref="/compliance"
      deleteAction={deleteRecord.bind(null, "compliance_items", id, "/compliance")}
    >
      <FormGrid>
        <FormSelect
          label="Entity type"
          name="entity_type"
          required
          defaultValue={item.entity_type}
          options={ENTITY_TYPES.map((t) => ({ value: t, label: t.charAt(0).toUpperCase() + t.slice(1) }))}
        />
        <FormField label="Entity ID" name="entity_id" required defaultValue={item.entity_id} />
        <FormSelect
          label="Requirement type"
          name="item_type"
          required
          defaultValue={item.item_type}
          options={ITEM_TYPES.map((t) => ({ value: t, label: t.replace(/_/g, " ") }))}
        />
        <FormField label="Expiry date" name="expiry_date" type="date" defaultValue={item.expiry_date} />
        <FormSelect
          label="Status"
          name="status"
          defaultValue={item.status}
          options={[
            { value: "valid", label: "Valid" },
            { value: "expiring_soon", label: "Expiring Soon" },
            { value: "expired", label: "Expired" },
            { value: "missing", label: "Missing" },
            { value: "waived", label: "Waived" },
          ]}
        />
        <FormTextarea label="Notes" name="notes" defaultValue={item.notes} />
      </FormGrid>
    </FormCard>
  );
}
