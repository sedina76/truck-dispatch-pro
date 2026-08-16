import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { updateInsurancePolicy } from "../actions";

export default async function InsurancePolicyDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const [{ data: policy }, { data: carriers }] = await Promise.all([
    supabase.from("insurance_policies").select("*").eq("id", id).single(),
    supabase.from("carriers").select("id, legal_name").order("legal_name"),
  ]);
  if (!policy) notFound();

  return (
    <FormCard
      title={`${policy.policy_type.replace(/_/g, " ")} -- ${policy.insurer_name}`}
      description="Policy details. Changes save immediately."
      action={updateInsurancePolicy.bind(null, id)}
      cancelHref="/compliance/insurance"
      deleteAction={deleteRecord.bind(null, "insurance_policies", id, "/compliance/insurance")}
    >
      <FormGrid>
        <FormSelect
          label="Policy type"
          name="policy_type"
          required
          defaultValue={policy.policy_type}
          options={[
            { value: "general_liability", label: "General Liability" },
            { value: "cargo", label: "Cargo" },
            { value: "physical_damage", label: "Physical Damage" },
            { value: "workers_compensation", label: "Workers Compensation" },
          ]}
        />
        <FormSelect
          label="Covers"
          name="carrier_id"
          defaultValue={policy.carrier_id}
          options={(carriers ?? []).map((c) => ({ value: c.id, label: c.legal_name }))}
        />
        <FormField label="Insurer name" name="insurer_name" defaultValue={policy.insurer_name} required />
        <FormField label="Policy number" name="policy_number" defaultValue={policy.policy_number} />
        <FormField label="Coverage amount ($)" name="coverage_amount" type="number" step="0.01" defaultValue={policy.coverage_amount} />
        <FormField label="Premium amount ($)" name="premium_amount" type="number" step="0.01" defaultValue={policy.premium_amount} />
        <FormField label="Effective date" name="effective_date" type="date" defaultValue={policy.effective_date} />
        <FormField label="Expiry date" name="expiry_date" type="date" defaultValue={policy.expiry_date} required />
        <FormTextarea label="Notes" name="notes" defaultValue={policy.notes} />
      </FormGrid>
    </FormCard>
  );
}
