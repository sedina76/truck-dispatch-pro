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

export default async function BrokerDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: broker } = await supabase.from("brokers").select("*").eq("id", id).single();
  if (!broker) notFound();

  const { data: loads } = await supabase
    .from("loads")
    .select("id, load_number, status, rate")
    .eq("broker_id", id)
    .order("created_at", { ascending: false })
    .limit(10);

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
          <FormField
            label="Payment terms (days)"
            name="payment_terms_days"
            type="number"
            defaultValue={broker.payment_terms_days}
          />
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

      <PartyArSection brokerId={id} />

      <BrokerProfitabilitySection brokerId={id} />

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
