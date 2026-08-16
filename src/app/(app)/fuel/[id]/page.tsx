import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { Button } from "@/components/ui/button";
import { ConfirmDeleteForm } from "@/components/ui/confirm-delete-form";
import { StatusBadge } from "@/components/ui/status-badge";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopCollapsibleSection, CollapsibleSectionsProvider, CollapsibleSectionsToolbar } from "@/components/desktop/collapsible-section";
import { FuelPurchaseFields } from "@/components/fuel/fuel-form-fields";
import { FuelEditForm } from "@/components/fuel/fuel-edit-form";
import { CreateFuelExpenseForm } from "@/components/fuel/create-fuel-expense-form";
import { PaymentResponsibilityFields } from "@/components/shared/payment-responsibility-fields";
import { FuelDocumentSlot } from "@/components/fuel/fuel-document-slot";
import { getLatestDocument } from "@/lib/documents/latest-document";
import { getFuelRecoveryStatus } from "../fuel-data";
import { deleteFuelLog } from "../actions";

const SECTION_DEFAULTS: Record<string, boolean> = { summary: true, purchase: true, cost: true, documents: false, activity: false };

const DOC_TYPES: { type: string; label: string }[] = [
  { type: "fuel_receipt", label: "Fuel Receipt" },
  { type: "expense_receipt", label: "Receipt" },
  { type: "other", label: "Other" },
];

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

async function deleteAndRedirect(id: string) {
  "use server";
  await deleteFuelLog(id);
  redirect("/fuel");
}

export default async function FuelLogDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: log } = await supabase.from("fuel_logs").select("*, carriers(legal_name)").eq("id", id).single();
  if (!log) notFound();

  const [{ data: trucksRaw }, { data: driversRaw }, recovery, documents, { data: activity }, { data: recoveryLines }, { data: driverRecoveryLines }] = await Promise.all([
    supabase.from("trucks").select("id, unit_number, carrier_id, ownership_type, current_odometer, carriers(legal_name)").order("unit_number"),
    supabase.from("drivers").select("id, carrier_id, first_name, last_name").eq("status", "active").order("last_name"),
    getFuelRecoveryStatus(supabase, id),
    Promise.all(DOC_TYPES.map((d) => getLatestDocument(supabase, "fuel", id, d.type))),
    supabase
      .from("activity_logs")
      .select("id, action, created_at, changes, profiles!activity_logs_actor_id_fkey(full_name)")
      .eq("entity_type", "fuel")
      .eq("entity_id", id)
      .order("created_at", { ascending: false })
      .limit(30),
    supabase.from("settlement_line_items").select("settlement_id, amount, settlements(settlement_number)").eq("linked_fuel_log_id", id),
    supabase.from("driver_settlement_adjustments").select("driver_settlement_id, amount, driver_settlements(settlement_number)").eq("linked_fuel_log_id", id),
  ]);

  const trucks = (trucksRaw ?? []).map((t) => {
    const row = t as unknown as { id: string; unit_number: string; carrier_id: string | null; ownership_type: string | null; current_odometer: number | null; carriers: { legal_name: string } | null };
    return { id: row.id, unit_number: row.unit_number, carrier_id: row.carrier_id, carrier_name: row.carriers?.legal_name ?? null, ownership_type: row.ownership_type, current_odometer: row.current_odometer };
  });

  const truck = trucks.find((t) => t.id === log.truck_id) ?? null;
  const locked = !!log.expense_id || Number(log.recovered_amount) > 0;

  const activityRows = (activity ?? []) as unknown as { id: string; action: string; created_at: string; profiles: { full_name: string } | null }[];
  const settlementNumbers = [
    ...((recoveryLines ?? []) as unknown as { settlements: { settlement_number: string } | null }[]).map((r) => r.settlements?.settlement_number).filter(Boolean),
    ...((driverRecoveryLines ?? []) as unknown as { driver_settlements: { settlement_number: string } | null }[]).map((r) => r.driver_settlements?.settlement_number).filter(Boolean),
  ] as string[];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Fuel Logs", href: "/fuel" }, { label: `${log.gallons} gal -- ${truck?.unit_number ?? "--"}`, href: `/fuel/${id}` }]} />

      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-base font-semibold text-desktop-text">Fuel Purchase -- {new Date(log.purchased_at).toLocaleDateString()}</h1>
          <p className="mt-0.5 flex items-center gap-1.5 text-[12px] text-desktop-text-muted">
            {truck?.unit_number ?? "--"} {log.carriers?.legal_name && `-- ${log.carriers.legal_name}`} -- {money(log.total_amount)}
          </p>
        </div>
        <div className="flex items-center gap-2">
          {!locked && <ConfirmDeleteForm action={deleteAndRedirect.bind(null, id)} />}
          <Link href="/fuel" className="inline-flex h-8 items-center rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">Back</Link>
        </div>
      </div>

      <CollapsibleSectionsProvider defaults={SECTION_DEFAULTS}>
        <CollapsibleSectionsToolbar />

        <div className="space-y-3">
          <DesktopCollapsibleSection id="summary" title="Fuel Log Summary">
            <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-[13px] sm:grid-cols-4">
              <SummaryField label="Fuel Log #" value={log.id.slice(0, 8).toUpperCase()} />
              <SummaryField label="Paid By" value={log.paid_by.replace(/_/g, " ")} />
              <SummaryField label="Recovery" value={log.recovery_type.replace(/_/g, " ")} />
              <SummaryField label="Recovery Status" value={<StatusBadge status={log.recovery_status} />} />
            </div>
          </DesktopCollapsibleSection>

          <DesktopCollapsibleSection id="purchase" title="Fuel Purchase Details">
            <FuelEditForm id={id}>
              <FuelPurchaseFields
                trucks={trucks}
                drivers={driversRaw ?? []}
                defaultTruckId={log.truck_id}
                defaultDriverId={log.driver_id}
                defaultGallons={log.gallons}
                defaultPricePerGallon={log.price_per_gallon}
                defaultTotalAmount={log.total_amount}
                defaultOdometerReading={log.odometer_reading}
                defaultState={log.state}
                defaultStationName={log.station_name}
                totalDisabled={locked}
                truckDisabled={locked}
              />
            </FuelEditForm>
            {locked && (
              <p className="mt-2 text-[11.5px] text-muted-foreground">
                Truck (and the carrier it derives) is frozen once an expense and/or recovery exists for this fuel log -- changing equipment after real money is attached would silently reassign a historical recovery to a different carrier. Void/adjust the linked expense or recovery first if this was logged against the wrong truck.
              </p>
            )}
            <div className="mt-3 flex items-center justify-end border-t border-desktop-border pt-3">
              <Button type="submit" form="fuel-edit-form">Save Changes</Button>
            </div>
          </DesktopCollapsibleSection>

          <DesktopCollapsibleSection id="payment" title="Payment & Responsibility">
            <PaymentResponsibilityFields
              drivers={driversRaw ?? []}
              defaultPaidBy={log.paid_by}
              defaultRecoveryType={log.recovery_type}
              defaultRecoverableAmount={log.recoverable_amount}
              defaultResponsibleDriverId={log.responsible_driver_id}
              formId="fuel-edit-form"
              disabled={locked}
              amountCapLabel="the fuel purchase total"
            />
            {locked && (
              <p className="mt-2 text-[11.5px] text-muted-foreground">
                Locked -- an expense and/or recovery already exists for this fuel log. Payment &amp; Responsibility changes are saved together with Fuel Purchase Details above only while unlocked.
              </p>
            )}
          </DesktopCollapsibleSection>

          <DesktopCollapsibleSection id="cost" title="Cost & Recovery">
            <div className="grid grid-cols-2 gap-x-4 gap-y-2 text-[13px] sm:grid-cols-4">
              <SummaryField label="Fuel Total" value={money(log.total_amount)} />
              <SummaryField label="Paid By" value={log.paid_by.replace(/_/g, " ")} />
              <SummaryField label="Expense #" value={log.expense_id ? <Link href={`/expenses/${log.expense_id}`} className="text-primary hover:underline">View Expense</Link> : "-- none --"} />
              <SummaryField label="Recovery From" value={log.recovery_type.replace(/_/g, " ")} />
              <SummaryField label="Recoverable Amount" value={money(recovery?.recoverableAmount ?? 0)} />
              <SummaryField label="Recovered Amount" value={money(recovery?.recoveredAmount ?? 0)} />
              <SummaryField label="Remaining" value={money(recovery?.remainingAmount ?? 0)} />
              <SummaryField label="Recovery Status" value={<StatusBadge status={recovery?.recoveryStatus ?? "not_applicable"} />} />
              <SummaryField label="Settlement #" value={settlementNumbers.length > 0 ? settlementNumbers.join(", ") : "-- none yet --"} />
            </div>
            {log.paid_by === "dispatch_company" && !log.expense_id && (
              <CreateFuelExpenseForm id={id} amountLabel={money(log.total_amount)} />
            )}
            {log.paid_by === "carrier" && (
              <p className="mt-3 border-t border-desktop-border pt-3 text-[11.5px] text-muted-foreground">
                Paid directly by the carrier -- this is an operational fuel record only. No company expense and no settlement deduction apply.
              </p>
            )}
            {log.paid_by === "driver" && (
              <p className="mt-3 border-t border-desktop-border pt-3 text-[11.5px] text-muted-foreground">
                Paid directly by the driver -- this is an operational fuel record only. No company expense or settlement deduction is created automatically. (No driver-reimbursement workflow exists in this app yet -- see report.)
              </p>
            )}
          </DesktopCollapsibleSection>

          <DesktopCollapsibleSection id="documents" title="Documents">
            {DOC_TYPES.map((d, i) => (
              <FuelDocumentSlot key={d.type} fuelLogId={id} documentType={d.type} label={d.label} doc={documents[i]} />
            ))}
          </DesktopCollapsibleSection>

          <DesktopCollapsibleSection id="activity" title="Activity History">
            {activityRows.length === 0 ? (
              <p className="text-[12.5px] text-muted-foreground">No activity recorded yet.</p>
            ) : (
              <div className="space-y-2">
                {activityRows.map((a) => (
                  <div key={a.id} className="flex items-center justify-between rounded-sm border border-desktop-border bg-desktop-panel px-3 py-2 text-[12.5px]">
                    <div>
                      <p className="font-medium text-desktop-text">{a.action.replace(/_/g, " ")}</p>
                      <p className="text-muted-foreground">by {a.profiles?.full_name ?? "Unknown"}</p>
                    </div>
                    <span className="text-[11px] text-muted-foreground">{new Date(a.created_at).toLocaleString()}</span>
                  </div>
                ))}
              </div>
            )}
          </DesktopCollapsibleSection>
        </div>
      </CollapsibleSectionsProvider>
    </div>
  );
}

function SummaryField({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div>
      <p className="text-[10.5px] font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className="capitalize text-desktop-text">{value}</p>
    </div>
  );
}
