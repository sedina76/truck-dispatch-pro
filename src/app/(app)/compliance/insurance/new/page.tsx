import { createClient } from "@/lib/supabase/server";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { createInsurancePolicy } from "../actions";

export default async function NewInsurancePolicyPage() {
  const supabase = await createClient();
  const { data: carriers } = await supabase.from("carriers").select("id, legal_name").order("legal_name");

  return (
    <FormCard
      title="Add Insurance Policy"
      description="Track a policy for your company or one of your carriers."
      action={createInsurancePolicy}
      cancelHref="/compliance/insurance"
      submitLabel="Add Policy"
    >
      <FormGrid>
        <FormSelect
          label="Policy type"
          name="policy_type"
          required
          options={[
            { value: "general_liability", label: "General Liability" },
            { value: "cargo", label: "Cargo" },
            { value: "physical_damage", label: "Physical Damage" },
            { value: "workers_compensation", label: "Workers Compensation" },
          ]}
        />
        <FormSelect
          label="Covers (leave blank for your own company policy)"
          name="carrier_id"
          options={(carriers ?? []).map((c) => ({ value: c.id, label: c.legal_name }))}
        />
        <FormField label="Insurer name" name="insurer_name" required />
        <FormField label="Policy number" name="policy_number" />
        <FormField label="Coverage amount ($)" name="coverage_amount" type="number" step="0.01" />
        <FormField label="Premium amount ($)" name="premium_amount" type="number" step="0.01" />
        <FormField label="Effective date" name="effective_date" type="date" />
        <FormField label="Expiry date" name="expiry_date" type="date" required />
        <FormTextarea label="Notes" name="notes" />
      </FormGrid>
    </FormCard>
  );
}
