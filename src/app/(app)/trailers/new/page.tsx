import { createClient } from "@/lib/supabase/server";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect } from "@/components/ui/form-field";
import { createTrailer } from "../actions";

export default async function NewTrailerPage() {
  const supabase = await createClient();
  const { data: carriers } = await supabase.from("carriers").select("id, legal_name").order("legal_name");

  return (
    <FormCard
      title="New Trailer"
      description="Add a trailer to your fleet."
      action={createTrailer}
      cancelHref="/trailers"
      submitLabel="Create Trailer"
    >
      <FormGrid>
        <FormSelect
          label="Carrier"
          name="carrier_id"
          options={(carriers ?? []).map((c) => ({ value: c.id, label: c.legal_name }))}
        />
        <FormField label="Unit number" name="unit_number" required placeholder="TR-201" />
        <FormSelect
          label="Trailer type"
          name="trailer_type"
          options={[
            { value: "dry_van", label: "Dry Van" },
            { value: "reefer", label: "Reefer" },
            { value: "flatbed", label: "Flatbed" },
            { value: "step_deck", label: "Step Deck" },
            { value: "lowboy", label: "Lowboy" },
            { value: "tanker", label: "Tanker" },
            { value: "other", label: "Other" },
          ]}
        />
        <FormField label="Length (ft)" name="length_ft" type="number" />
        <FormField label="License plate" name="license_plate" />
        <FormField label="License state" name="license_state" placeholder="IL" />
        <FormSelect
          label="Ownership type"
          name="ownership_type"
          options={[
            { value: "owned", label: "Owned" },
            { value: "leased", label: "Leased" },
            { value: "owner_operator", label: "Owner-operator" },
          ]}
        />
        <FormSelect
          label="Status"
          name="status"
          defaultValue="active"
          options={[
            { value: "active", label: "Active" },
            { value: "in_maintenance", label: "In Maintenance" },
            { value: "out_of_service", label: "Out of Service" },
            { value: "inactive", label: "Inactive" },
          ]}
        />
        <FormField label="Registration expiry" name="registration_expiry_date" type="date" />
        <FormField label="Annual inspection expiry" name="annual_inspection_expiry_date" type="date" />
      </FormGrid>
    </FormCard>
  );
}
