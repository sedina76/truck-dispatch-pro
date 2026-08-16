import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormTextarea } from "@/components/ui/form-field";
import { createBroker } from "../actions";

export default function NewBrokerPage() {
  return (
    <FormCard
      title="New Broker"
      description="Add a freight broker you book loads from."
      action={createBroker}
      cancelHref="/brokers"
      submitLabel="Create Broker"
    >
      <FormGrid>
        <FormField label="Company name" name="company_name" required />
        <FormField label="MC number" name="mc_number" placeholder="MC-123456" />
        <FormField label="Contact name" name="contact_name" />
        <FormField label="Phone" name="phone" type="tel" />
        <FormField label="Email" name="email" type="email" />
        <FormField label="City" name="city" />
        <FormField label="State" name="state" placeholder="IL" />
        <FormField label="Payment terms (days)" name="payment_terms_days" type="number" defaultValue={30} />
        <FormTextarea label="Notes" name="notes" />
      </FormGrid>
    </FormCard>
  );
}
