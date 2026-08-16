import { createClient } from "@/lib/supabase/server";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect } from "@/components/ui/form-field";
import { createDriverSettlement } from "../actions";

function isoDate(d: Date) {
  return d.toISOString().slice(0, 10);
}

export default async function NewDriverSettlementPage() {
  const supabase = await createClient();
  const { data: drivers } = await supabase.from("drivers").select("id, first_name, last_name").eq("status", "active").order("first_name");

  // Default period: the last 7 days (weekly, spec section 6's suggested default).
  const today = new Date();
  const weekAgo = new Date(today);
  weekAgo.setDate(weekAgo.getDate() - 6);

  return (
    <FormCard
      title="New Settlement"
      description="Select a driver and period -- eligible delivered loads not already settled will be added automatically. Review before approving."
      action={createDriverSettlement}
      cancelHref="/driver-settlements"
      submitLabel="Create Settlement"
    >
      <FormGrid>
        <FormSelect
          label="Driver"
          name="driver_id"
          required
          options={(drivers ?? []).map((d) => ({ value: d.id, label: `${d.first_name} ${d.last_name}` }))}
        />
        <FormField label="Period Start" name="period_start" type="date" defaultValue={isoDate(weekAgo)} required />
        <FormField label="Period End" name="period_end" type="date" defaultValue={isoDate(today)} required />
      </FormGrid>
    </FormCard>
  );
}
