import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormTextarea } from "@/components/ui/form-field";
import { StatusBadge } from "@/components/ui/status-badge";
import { PartyArSection } from "@/components/finance/party-ar-section";
import { BrokerProfitabilitySection } from "@/components/brokers/broker-profitability-section";
import { updateBroker } from "../actions";
import { FINANCIAL_ROLES, type OrgRole } from "@/lib/auth/require-role";

// Phase 2G.9 (item 3): same treatment as Customer Detail -- Brokers is
// Business, open to every role, no layout guard.
export default async function BrokerDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: roleData } = await supabase.rpc("current_role");
  const canSeeFinancials = FINANCIAL_ROLES.includes((roleData as OrgRole | null) ?? ("viewer" as OrgRole));

  const { data: broker } = await supabase.from("brokers").select("*").eq("id", id).single();
  if (!broker) notFound();

  // Phase 2G.12: payment_terms_days moved to broker_financials (2G.10
  // writer cutover) -- brokers' own copy is stale the moment it's edited.
  // credit_rating has no reader anywhere in this app (confirmed by
  // inspection) so there's nothing to display/cut over for it here.
  const { data: brokerFinancials } = canSeeFinancials
    ? await supabase.from("broker_financials").select("payment_terms_days").eq("broker_id", id).maybeSingle()
    : { data: null };

  // `rate` dropped from this select -- see identical fix/reasoning in
  // customers/[id]/page.tsx.
  const { data: loadsData } = await supabase
    .from("loads")
    .select("id, load_number, status")
    .eq("broker_id", id)
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
        title={broker.company_name}
        description="Broker profile. Changes save immediately."
        action={updateBroker.bind(null, id)}
        cancelHref="/brokers"
        deleteAction={deleteRecord.bind(null, "brokers", id, "/brokers")}
      >
        <FormGrid>
          <FormField label="Company name" name="company_name" defaultValue={broker.company_name} required />
          <FormField label="MC number" name="mc_number" defaultValue={broker.mc_number} />
          <FormField label="Contact name" name="contact_name" defaultValue={broker.contact_name} />
          <FormField label="Phone" name="phone" type="tel" defaultValue={broker.phone} />
          <FormField label="Email" name="email" type="email" defaultValue={broker.email} />
          <FormField label="City" name="city" defaultValue={broker.city} />
          <FormField label="State" name="state" defaultValue={broker.state} />
          {canSeeFinancials && (
            <FormField
              label="Payment terms (days)"
              name="payment_terms_days"
              type="number"
              defaultValue={brokerFinancials?.payment_terms_days}
            />
          )}
          <label className="flex items-center gap-2 text-sm font-medium sm:col-span-2">
            <input
              type="checkbox"
              name="is_blacklisted"
              defaultChecked={broker.is_blacklisted}
              className="size-4 rounded border-[var(--color-border)]"
            />
            Blacklisted (do not book loads from this broker)
          </label>
          <FormTextarea label="Notes" name="notes" defaultValue={broker.notes} />
        </FormGrid>
      </FormCard>

      {canSeeFinancials && <PartyArSection brokerId={id} />}

      {canSeeFinancials && <BrokerProfitabilitySection brokerId={id} />}

      <div className="rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] p-4">
        <p className="text-sm font-medium">Recent loads</p>
        {!loads || loads.length === 0 ? (
          <p className="mt-2 text-sm text-[var(--color-text-muted)]">No loads from this broker yet.</p>
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
