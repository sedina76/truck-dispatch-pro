import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid } from "@/components/ui/form-field";
import { StatusBadge } from "@/components/ui/status-badge";
import { PartyArSection } from "@/components/finance/party-ar-section";
import { CustomerProfitabilitySection } from "@/components/customers/customer-profitability-section";
import { updateCustomer } from "../actions";

export default async function CustomerDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: customer } = await supabase.from("customers").select("*").eq("id", id).single();
  if (!customer) notFound();

  const { data: loads } = await supabase
    .from("loads")
    .select("id, load_number, status, rate")
    .eq("customer_id", id)
    .order("created_at", { ascending: false })
    .limit(10);

  return (
    <div className="space-y-6">
      <FormCard
        title={customer.company_name}
        description="Customer profile. Changes save immediately."
        action={updateCustomer.bind(null, id)}
        cancelHref="/customers"
        deleteAction={deleteRecord.bind(null, "customers", id, "/customers")}
      >
        <FormGrid>
          <FormField label="Company name" name="company_name" defaultValue={customer.company_name} required />
          <FormField label="Contact name" name="contact_name" defaultValue={customer.contact_name} />
          <FormField label="Phone" name="phone" type="tel" defaultValue={customer.phone} />
          <FormField label="Email" name="email" type="email" defaultValue={customer.email} />
          <FormField label="City" name="city" defaultValue={customer.city} />
          <FormField label="State" name="state" defaultValue={customer.state} />
          <FormField
            label="Payment terms (days)"
            name="payment_terms_days"
            type="number"
            defaultValue={customer.payment_terms_days}
          />
          <label className="flex items-center gap-2 text-sm font-medium">
            <input
              type="checkbox"
              name="is_active"
              defaultChecked={customer.is_active}
              className="size-4 rounded border-[var(--color-border)]"
            />
            Active
          </label>
        </FormGrid>
      </FormCard>

      <PartyArSection customerId={id} />

      <CustomerProfitabilitySection customerId={id} />

      <div className="rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] p-4">
        <p className="text-sm font-medium">Recent loads</p>
        {!loads || loads.length === 0 ? (
          <p className="mt-2 text-sm text-[var(--color-text-muted)]">No loads for this customer yet.</p>
        ) : (
          <ul className="mt-2 divide-y divide-[var(--color-border)]">
            {loads.map((load) => (
              <li key={load.id} className="flex items-center justify-between py-2 text-sm">
                <Link href={`/loads/${load.id}`} className="font-medium text-[var(--color-brand)]">
                  {load.load_number}
                </Link>
                <span>${Number(load.rate).toLocaleString()}</span>
                <StatusBadge status={load.status} />
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
