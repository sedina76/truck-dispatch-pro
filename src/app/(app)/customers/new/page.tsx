import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid } from "@/components/ui/form-field";
import { createCustomer } from "../actions";

export default function NewCustomerPage() {
  return (
    <FormCard
      title="New Customer"
      description="Add a direct shipper relationship outside the broker network."
      action={createCustomer}
      cancelHref="/customers"
      submitLabel="Create Customer"
    >
      <FormGrid>
        <FormField label="Company name" name="company_name" required />
        <FormField label="Contact name" name="contact_name" />
        <FormField label="Phone" name="phone" type="tel" />
        <FormField label="Email" name="email" type="email" />
        <FormField label="City" name="city" />
        <FormField label="State" name="state" placeholder="IL" />
        <FormField label="Payment terms (days)" name="payment_terms_days" type="number" defaultValue={30} />
        <label className="flex items-center gap-2 text-sm font-medium">
          <input type="checkbox" name="is_active" defaultChecked className="size-4 rounded border-[var(--color-border)]" />
          Active
        </label>
      </FormGrid>
    </FormCard>
  );
}
