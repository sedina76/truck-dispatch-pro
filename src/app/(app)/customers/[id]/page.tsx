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
import { FINANCIAL_ROLES, type OrgRole } from "@/lib/auth/require-role";

// Phase 2G.9 (item 3): Customers is Business, open to every role, no
// layout guard -- payment_terms_days, the AR section, the profitability
// section, and per-load rate in "Recent loads" were all unconditional.
export default async function CustomerDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: roleData } = await supabase.rpc("current_role");
  const canSeeFinancials = FINANCIAL_ROLES.includes((roleData as OrgRole | null) ?? ("viewer" as OrgRole));

  const { data: customer } = await supabase.from("customers").select("*").eq("id", id).single();
  if (!customer) notFound();

  // Phase 2G.12: payment_terms_days moved to customer_financials (2G.10
  // writer cutover) -- customers' own copy is stale the moment it's
  // edited. Fetched only for canSeeFinancials.
  const { data: customerFinancials } = canSeeFinancials
    ? await supabase.from("customer_financials").select("payment_terms_days").eq("customer_id", id).maybeSingle()
    : { data: null };

  // `rate` dropped from this select -- 0068's writer cutover stopped
  // populating loads.rate; load_financials is authoritative now, merged
  // in below by load id, fetched only for canSeeFinancials (this select
  // was already role-branched for the column list, just against the
  // wrong source).
  const { data: loadsData } = await supabase
    .from("loads")
    .select("id, load_number, status")
    .eq("customer_id", id)
    .order("created_at", { ascending: false })
    .limit(10);
  const loadsRaw = (loadsData ?? []) as { id: string; load_number: string; status: string }[];
  const rateByLoadId = new Map<string, number>();
  if (canSeeFinancials && loadsRaw.length > 0) {
    const { data: lf } = await supabase.from("load_financials").select("load_id, rate").in("load_id", loadsRaw.map((l) => l.id));
    for (const row of lf ?? []) rateByLoadId.set(row.load_id, Number(row.rate));
  }
  const loads = loadsRaw.map((l) => ({ ...l, rate: rateByLoadId.get(l.id) }));

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
          {canSeeFinancials && (
            <FormField
              label="Payment terms (days)"
              name="payment_terms_days"
              type="number"
              defaultValue={customerFinancials?.payment_terms_days}
            />
          )}
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

      {canSeeFinancials && <PartyArSection customerId={id} />}

      {canSeeFinancials && <CustomerProfitabilitySection customerId={id} />}

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
                {canSeeFinancials && <span>${Number(load.rate ?? 0).toLocaleString()}</span>}
                <StatusBadge status={load.status} />
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
