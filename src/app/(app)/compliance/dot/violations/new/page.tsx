import { createClient } from "@/lib/supabase/server";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { createDotViolation } from "../../actions";

export default async function NewDotViolationPage() {
  const supabase = await createClient();
  const [{ data: carriers }, { data: drivers }] = await Promise.all([
    supabase.from("carriers").select("id, legal_name").order("legal_name"),
    supabase.from("drivers").select("id, first_name, last_name").order("last_name"),
  ]);

  return (
    <FormCard
      title="Log DOT Violation"
      description="Record a violation from a roadside inspection or audit."
      action={createDotViolation}
      cancelHref="/compliance/dot"
      submitLabel="Log Violation"
    >
      <FormGrid>
        <FormField label="Violation date" name="violation_date" type="date" required defaultValue={new Date().toISOString().slice(0, 10)} />
        <FormField label="Violation type" name="violation_type" required placeholder="Hours of Service, Vehicle Defect, ..." />
        <FormSelect
          label="Carrier"
          name="carrier_id"
          options={(carriers ?? []).map((c) => ({ value: c.id, label: c.legal_name }))}
        />
        <FormSelect
          label="Driver"
          name="driver_id"
          options={(drivers ?? []).map((d) => ({ value: d.id, label: `${d.first_name} ${d.last_name}` }))}
        />
        <FormSelect
          label="Severity"
          name="severity"
          defaultValue="medium"
          options={[
            { value: "low", label: "Low" },
            { value: "medium", label: "Medium" },
            { value: "high", label: "High" },
            { value: "critical", label: "Critical" },
          ]}
        />
        <FormTextarea label="Description" name="description" />
      </FormGrid>
    </FormCard>
  );
}
