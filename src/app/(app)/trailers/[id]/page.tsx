import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect } from "@/components/ui/form-field";
import { updateTrailer } from "../actions";

export default async function TrailerDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const [{ data: trailer }, { data: carriers }, { data: maintenance }] = await Promise.all([
    supabase.from("trailers").select("*").eq("id", id).single(),
    supabase.from("carriers").select("id, legal_name").order("legal_name"),
    supabase
      .from("maintenance_records")
      .select("id, service_type, cost, service_date")
      .eq("trailer_id", id)
      .order("service_date", { ascending: false })
      .limit(5),
  ]);
  if (!trailer) notFound();

  return (
    <div className="space-y-6">
      <FormCard
        title={`Trailer ${trailer.unit_number}`}
        description="Trailer profile. Changes save immediately."
        action={updateTrailer.bind(null, id)}
        cancelHref="/trailers"
        deleteAction={deleteRecord.bind(null, "trailers", id, "/trailers")}
      >
        <FormGrid>
          {/* Phase 3A.1 hotfix: trailers.carrier_id is no longer directly
              UPDATE-able by authenticated users (0134 column-privilege
              correction) -- changing a trailer's carrier ownership after
              creation requires an owner/admin using the guarded
              approve_trailer_ownership_scope() RPC, which has no dedicated
              UI yet. Disabled here (not removed) so the current value stays
              visible; the field is set at creation and stops being a plain
              editable form field on this page from here on. */}
          <FormSelect
            label="Carrier (set at creation — an owner/admin must change this)"
            name="carrier_id"
            defaultValue={trailer.carrier_id}
            options={(carriers ?? []).map((c) => ({ value: c.id, label: c.legal_name }))}
            disabled
          />
          <FormField label="Unit number" name="unit_number" defaultValue={trailer.unit_number} required />
          <FormSelect
            label="Trailer type"
            name="trailer_type"
            defaultValue={trailer.trailer_type}
            options={[
              { value: "dry_van", label: "Dry Van" },
              { value: "reefer", label: "Reefer" },
              { value: "flatbed", label: "Flatbed" },
              { value: "step_deck", label: "Step Deck" },
              { value: "lowboy", label: "Lowboy" },
              { value: "tanker", label: "Tanker" },
              { value: "other", label: "Other" },
            ]}
          />
          <FormField label="Length (ft)" name="length_ft" type="number" defaultValue={trailer.length_ft} />
          <FormField label="License plate" name="license_plate" defaultValue={trailer.license_plate} />
          <FormField label="License state" name="license_state" defaultValue={trailer.license_state} />
          <FormSelect
            label="Ownership type"
            name="ownership_type"
            defaultValue={trailer.ownership_type}
            options={[
              { value: "owned", label: "Owned" },
              { value: "leased", label: "Leased" },
              { value: "owner_operator", label: "Owner-operator" },
            ]}
          />
          <FormSelect
            label="Status"
            name="status"
            defaultValue={trailer.status}
            options={[
              { value: "active", label: "Active" },
              { value: "in_maintenance", label: "In Maintenance" },
              { value: "out_of_service", label: "Out of Service" },
              { value: "inactive", label: "Inactive" },
            ]}
          />
          <FormField label="Registration expiry" name="registration_expiry_date" type="date" defaultValue={trailer.registration_expiry_date} />
          <FormField label="Annual inspection expiry" name="annual_inspection_expiry_date" type="date" defaultValue={trailer.annual_inspection_expiry_date} />
        </FormGrid>
      </FormCard>

      <div className="rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] p-4">
        <p className="text-sm font-medium">Recent maintenance</p>
        {!maintenance || maintenance.length === 0 ? (
          <p className="mt-2 text-sm text-[var(--color-text-muted)]">No records yet.</p>
        ) : (
          <ul className="mt-2 space-y-1 text-sm">
            {maintenance.map((m) => (
              <li key={m.id} className="flex justify-between">
                <span>{m.service_type}</span>
                <span>${Number(m.cost).toLocaleString()}</span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
