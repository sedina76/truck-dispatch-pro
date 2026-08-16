import { createClient } from "@/lib/supabase/server";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect } from "@/components/ui/form-field";
import { createTruck } from "../actions";

export default async function NewTruckPage() {
  const supabase = await createClient();
  const { data: carriers } = await supabase.from("carriers").select("id, legal_name").order("legal_name");

  return (
    <FormCard
      title="New Truck"
      description="Add a truck to one of your carriers' fleets."
      action={createTruck}
      cancelHref="/trucks"
      submitLabel="Create Truck"
    >
      <FormGrid>
        <FormSelect
          label="Carrier"
          name="carrier_id"
          required
          options={(carriers ?? []).map((c) => ({ value: c.id, label: c.legal_name }))}
        />
        <FormField label="Unit number" name="unit_number" required placeholder="T-101" />
        <FormField label="VIN" name="vin" />
        <FormField label="Make" name="make" />
        <FormField label="Model" name="model" />
        <FormField label="Year" name="year" type="number" />
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
        <FormField label="Current odometer" name="current_odometer" type="number" />
        <FormField label="Registration expiry" name="registration_expiry_date" type="date" />
        <FormField label="Annual inspection expiry" name="annual_inspection_expiry_date" type="date" />
      </FormGrid>
    </FormCard>
  );
}
