import { createClient } from "@/lib/supabase/server";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect } from "@/components/ui/form-field";
import { createCarrierSettlement } from "../actions";

function isoDate(d: Date) {
  return d.toISOString().slice(0, 10);
}

export default async function NewCarrierSettlementPage() {
  const supabase = await createClient();
  const { data: carriers } = await supabase.from("carriers").select("id, legal_name").eq("is_active", true).order("legal_name");

  const today = new Date();
  const weekAgo = new Date(today);
  weekAgo.setDate(weekAgo.getDate() - 6);

  return (
    <FormCard
      title="New Carrier Settlement"
      description="Select a carrier and period -- eligible delivered loads not already settled will be added automatically, using each dispatch's own snapshotted carrier rate. Review before approving."
      action={createCarrierSettlement}
      cancelHref="/settlements"
      submitLabel="Create Settlement"
    >
      <FormGrid>
        <FormSelect
          label="Carrier"
          name="carrier_id"
          required
          options={(carriers ?? []).map((c) => ({ value: c.id, label: c.legal_name }))}
        />
        <FormField label="Period Start" name="period_start" type="date" defaultValue={isoDate(weekAgo)} required />
        <FormField label="Period End" name="period_end" type="date" defaultValue={isoDate(today)} required />
      </FormGrid>
    </FormCard>
  );
}
