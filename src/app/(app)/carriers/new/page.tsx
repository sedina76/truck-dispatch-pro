import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid } from "@/components/ui/form-field";
import { createCarrier } from "../actions";

export default function NewCarrierPage() {
  return (
    <FormCard
      title="New Carrier"
      description="Onboard a new carrier and set their default dispatch fee."
      action={createCarrier}
      cancelHref="/carriers"
      submitLabel="Create Carrier"
    >
      <FormGrid>
        <FormField label="Legal name" name="legal_name" required />
        <FormField label="DBA name" name="dba_name" />
        <FormField label="MC number" name="mc_number" placeholder="MC-123456" />
        <FormField label="DOT number" name="dot_number" placeholder="DOT-1234567" />
        <FormField label="Contact name" name="contact_name" />
        <FormField label="Phone" name="phone" type="tel" />
        <FormField label="Email" name="email" type="email" />
        <FormField label="City" name="city" />
        <FormField label="State" name="state" placeholder="IL" />
        <FormField
          label="Dispatch fee %"
          name="dispatch_fee_percentage"
          type="number"
          step="0.01"
          defaultValue={10}
          required
        />
        <FormField
          label="Payment terms (days)"
          name="payment_terms_days"
          type="number"
          defaultValue={7}
        />
      </FormGrid>
    </FormCard>
  );
}
