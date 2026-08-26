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
        <FormField label="Legal name" name="legal_name" required />
        <FormField label="DBA name" name="dba_name" />
        <FormField label="MC number" name="mc_number" placeholder="MC-123456" />
        <FormField label="USDOT number" name="dot_number" />
        <FormField label="Website" name="website" type="url" />
        <FormField label="Contact name" name="contact_name" />
        <FormField label="Phone" name="phone" type="tel" />
        <FormField label="Email" name="email" type="email" />
        <FormField label="City" name="city" />
        <FormField label="State" name="state" placeholder="IL" />
        <label className="space-y-1 text-sm"><span className="font-medium">Status</span><select name="status" className="h-9 w-full rounded-md border bg-background px-3"><option value="prospect">Prospect</option><option value="setup_pending">Setup Pending</option><option value="active">Active</option><option value="inactive">Inactive</option><option value="do_not_use">Do Not Use</option></select></label>
        <label className="space-y-1 text-sm"><span className="font-medium">Onboarding</span><select name="onboarding_status" className="h-9 w-full rounded-md border bg-background px-3"><option value="not_started">Not Started</option><option value="collecting">Collecting</option><option value="ready">Ready</option><option value="complete">Complete</option></select></label>
        <FormField label="Payment terms (days)" name="payment_terms_days" type="number" defaultValue={30} />
        <FormTextarea label="Notes" name="notes" />
      </FormGrid>
    </FormCard>
  );
}
