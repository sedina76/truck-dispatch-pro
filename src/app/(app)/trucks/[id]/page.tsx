import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect } from "@/components/ui/form-field";
import { updateTruck } from "../actions";
import { TruckExpenseSummarySection } from "@/components/trucks/truck-expense-summary-section";

export default async function TruckDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const [{ data: truck }, { data: carriers }, { data: assignment }, { data: maintenance }, { data: fuel }] =
    await Promise.all([
      supabase.from("trucks").select("*").eq("id", id).single(),
      supabase.from("carriers").select("id, legal_name").order("legal_name"),
      supabase
        .from("truck_driver_assignments")
        .select("drivers(first_name, last_name)")
        .eq("truck_id", id)
        .eq("is_current", true)
        .maybeSingle(),
      supabase
        .from("maintenance_records")
        .select("id, service_type, cost, service_date")
        .eq("truck_id", id)
        .order("service_date", { ascending: false })
        .limit(5),
      supabase
        .from("fuel_logs")
        .select("id, gallons, total_amount, purchased_at")
        .eq("truck_id", id)
        .order("purchased_at", { ascending: false })
        .limit(5),
    ]);
  if (!truck) notFound();

  const currentDriver = (assignment as unknown as { drivers: { first_name: string; last_name: string } | null })
    ?.drivers;

  return (
    <div className="space-y-6">
      <FormCard
        title={`Truck ${truck.unit_number}`}
        description="Truck profile. Changes save immediately."
        action={updateTruck.bind(null, id)}
        cancelHref="/trucks"
        deleteAction={deleteRecord.bind(null, "trucks", id, "/trucks")}
      >
        <FormGrid>
          <FormSelect
            label="Carrier"
            name="carrier_id"
            required
            defaultValue={truck.carrier_id}
            options={(carriers ?? []).map((c) => ({ value: c.id, label: c.legal_name }))}
          />
          <FormField label="Unit number" name="unit_number" defaultValue={truck.unit_number} required />
          <FormField label="VIN" name="vin" defaultValue={truck.vin} />
          <FormField label="Make" name="make" defaultValue={truck.make} />
          <FormField label="Model" name="model" defaultValue={truck.model} />
          <FormField label="Year" name="year" type="number" defaultValue={truck.year} />
          <FormField label="License plate" name="license_plate" defaultValue={truck.license_plate} />
          <FormField label="License state" name="license_state" defaultValue={truck.license_state} />
          <FormSelect
            label="Ownership type"
            name="ownership_type"
            defaultValue={truck.ownership_type}
            options={[
              { value: "owned", label: "Owned" },
              { value: "leased", label: "Leased" },
              { value: "owner_operator", label: "Owner-operator" },
            ]}
          />
          <FormSelect
            label="Status"
            name="status"
            defaultValue={truck.status}
            options={[
              { value: "active", label: "Active" },
              { value: "in_maintenance", label: "In Maintenance" },
              { value: "out_of_service", label: "Out of Service" },
              { value: "inactive", label: "Inactive" },
            ]}
          />
          <FormField label="Current odometer" name="current_odometer" type="number" defaultValue={truck.current_odometer} />
          <FormField label="Registration expiry" name="registration_expiry_date" type="date" defaultValue={truck.registration_expiry_date} />
          <FormField label="Annual inspection expiry" name="annual_inspection_expiry_date" type="date" defaultValue={truck.annual_inspection_expiry_date} />
        </FormGrid>
      </FormCard>

      <TruckExpenseSummarySection truckId={id} />

      <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
        <div className="rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] p-4">
          <p className="text-sm font-medium">Current driver</p>
          <p className="mt-2 text-sm text-[var(--color-text-muted)]">
            {currentDriver ? `${currentDriver.first_name} ${currentDriver.last_name}` : "Unassigned"}
          </p>
        </div>
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
        <div className="rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] p-4">
          <p className="text-sm font-medium">Recent fuel</p>
          {!fuel || fuel.length === 0 ? (
            <p className="mt-2 text-sm text-[var(--color-text-muted)]">No fuel logs yet.</p>
          ) : (
            <ul className="mt-2 space-y-1 text-sm">
              {fuel.map((f) => (
                <li key={f.id} className="flex justify-between">
                  <span>{Number(f.gallons).toFixed(1)} gal</span>
                  <span>${Number(f.total_amount).toLocaleString()}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </div>
  );
}
