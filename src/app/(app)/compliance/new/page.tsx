import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { createComplianceItem } from "../actions";

const ENTITY_TYPES = ["carrier", "driver", "truck", "trailer"];
const ITEM_TYPES = [
  "cdl_expiry",
  "medical_card_expiry",
  "insurance_expiry",
  "registration_expiry",
  "authority_expiry",
  "annual_inspection",
  "drug_test",
  "ifta_renewal",
  "other",
];

export default function NewComplianceItemPage() {
  return (
    <FormCard
      title="New Compliance Item"
      description="Track an expiring credential for a driver, carrier, truck, or trailer."
      action={createComplianceItem}
      cancelHref="/compliance"
      submitLabel="Add Item"
    >
      <FormGrid>
        <FormSelect
          label="Entity type"
          name="entity_type"
          required
          options={ENTITY_TYPES.map((t) => ({ value: t, label: t.charAt(0).toUpperCase() + t.slice(1) }))}
        />
        <FormField label="Entity ID" name="entity_id" required placeholder="Paste the ID of the related record" />
        <FormSelect
          label="Requirement type"
          name="item_type"
          required
          options={ITEM_TYPES.map((t) => ({ value: t, label: t.replace(/_/g, " ") }))}
        />
        <FormField label="Expiry date" name="expiry_date" type="date" />
        <FormSelect
          label="Status"
          name="status"
          defaultValue="valid"
          options={[
            { value: "valid", label: "Valid" },
            { value: "expiring_soon", label: "Expiring Soon" },
            { value: "expired", label: "Expired" },
            { value: "missing", label: "Missing" },
            { value: "waived", label: "Waived" },
          ]}
        />
        <FormTextarea label="Notes" name="notes" />
      </FormGrid>
    </FormCard>
  );
}
