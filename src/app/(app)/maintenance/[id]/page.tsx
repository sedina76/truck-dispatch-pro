import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { Button } from "@/components/ui/button";
import { StatusBadge } from "@/components/ui/status-badge";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopCollapsibleSection, CollapsibleSectionsProvider, CollapsibleSectionsToolbar } from "@/components/desktop/collapsible-section";
import { EquipmentServiceFields, PaymentResponsibilityFields } from "@/components/maintenance/maintenance-form-fields";
import { MaintenanceDocumentSlot } from "@/components/maintenance/maintenance-document-slot";
import { getLatestDocument } from "@/lib/documents/latest-document";
import { computePreventiveMaintenanceStatus, getRecoveryStatus } from "../maintenance-data";
import { updateMaintenanceRecord, createMaintenanceExpense, setMaintenanceStatus, setEquipmentStatusFromMaintenance } from "../actions";

const SECTION_DEFAULTS: Record<string, boolean> = { summary: true, equipment: true, cost: true, preventive: false, documents: false, activity: false };

const DOC_TYPES: { type: string; label: string }[] = [
  { type: "repair_invoice", label: "Repair Invoice" },
  { type: "expense_receipt", label: "Receipt" },
  { type: "estimate", label: "Estimate" },
  { type: "inspection_report", label: "Inspection Report" },
  { type: "before_photo", label: "Before Photo" },
  { type: "after_photo", label: "After Photo" },
  { type: "other", label: "Other" },
];

const PM_STATUS_LABEL: Record<string, string> = { not_scheduled: "Not Scheduled", ok: "OK", due_soon: "Due Soon", due: "Due", overdue: "Overdue" };
function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

async function createExpenseAction(id: string) {
  "use server";
  await createMaintenanceExpense(id);
}

export default async function MaintenanceDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: record } = await supabase.from("maintenance_records").select("*, carriers(legal_name)").eq("id", id).single();
  if (!record) notFound();

  const [{ data: trucksRaw }, { data: trailersRaw }, { data: driversRaw }, recovery, documents, { data: activity }] = await Promise.all([
    supabase.from("trucks").select("id, unit_number, carrier_id, ownership_type, status, current_odometer, carriers(legal_name)").order("unit_number"),
    supabase.from("trailers").select("id, unit_number, carrier_id, ownership_type, status, carriers(legal_name)").order("unit_number"),
    supabase.from("drivers").select("id, carrier_id, first_name, last_name").eq("status", "active").order("last_name"),
    getRecoveryStatus(supabase, id),
    Promise.all(DOC_TYPES.map((d) => getLatestDocument(supabase, "maintenance", id, d.type))),
    supabase
      .from("activity_logs")
      .select("id, action, created_at, changes, profiles!activity_logs_actor_id_fkey(full_name)")
      .eq("entity_type", "maintenance")
      .eq("entity_id", id)
      .order("created_at", { ascending: false })
      .limit(30),
  ]);

  const trucks = (trucksRaw ?? []).map((t) => {
    const row = t as unknown as { id: string; unit_number: string; carrier_id: string | null; ownership_type: string | null; status: string; current_odometer: number | null; carriers: { legal_name: string } | null };
    return { id: row.id, unit_number: row.unit_number, carrier_id: row.carrier_id, carrier_name: row.carriers?.legal_name ?? null, ownership_type: row.ownership_type, status: row.status, current_odometer: row.current_odometer };
  });
  const trailers = (trailersRaw ?? []).map((t) => {
    const row = t as unknown as { id: string; unit_number: string; carrier_id: string | null; ownership_type: string | null; status: string; carriers: { legal_name: string } | null };
    return { id: row.id, unit_number: row.unit_number, carrier_id: row.carrier_id, carrier_name: row.carriers?.legal_name ?? null, ownership_type: row.ownership_type, status: row.status };
  });

  const equipment = trucks.find((t) => t.id === record.truck_id) ?? trailers.find((t) => t.id === record.trailer_id) ?? null;
  const isOutOfService = equipment?.status === "out_of_service" || equipment?.status === "in_maintenance";
  const locked = !!record.expense_id || Number(record.recovered_amount) > 0;
  const pmStatus = computePreventiveMaintenanceStatus(record.next_service_due_date, record.next_service_due_odometer, record.truck_id ? (equipment as { current_odometer?: number | null } | null)?.current_odometer ?? null : null);

  const activityRows = (activity ?? []) as unknown as { id: string; action: string; created_at: string; profiles: { full_name: string } | null }[];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Maintenance", href: "/maintenance" }, { label: record.service_type, href: `/maintenance/${id}` }]} />

      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-base font-semibold text-desktop-text">{record.service_type}</h1>
          <p className="mt-0.5 flex items-center gap-1.5 text-[12px] text-desktop-text-muted">
            <StatusBadge status={record.status} /> {equipment?.unit_number ?? "--"} {record.carriers?.legal_name && `-- ${record.carriers.legal_name}`}
          </p>
        </div>
        <div className="flex items-center gap-2">
          {record.status === "open" && (
            <form action={setMaintenanceStatus.bind(null, id, "completed")}>
              <Button type="submit" size="sm" variant="outline">Mark Completed</Button>
            </form>
          )}
          {record.status !== "cancelled" && (
            <form action={setMaintenanceStatus.bind(null, id, "cancelled")} onSubmit={(e) => { if (!confirm("Cancel this maintenance record?")) e.preventDefault(); }}>
              <Button type="submit" size="sm" variant="danger">Cancel</Button>
            </form>
          )}
          <Link href="/maintenance" className="inline-flex h-8 items-center rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">Back</Link>
        </div>
      </div>

      <CollapsibleSectionsProvider defaults={SECTION_DEFAULTS}>
        <CollapsibleSectionsToolbar />

        <div className="space-y-3">
          <DesktopCollapsibleSection id="summary" title="Maintenance Summary">
            <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-[13px] sm:grid-cols-4">
              <SummaryField label="Status" value={<StatusBadge status={record.status} />} />
              <SummaryField label="Paid By" value={record.paid_by.replace(/_/g, " ")} />
              <SummaryField label="Recovery" value={record.recovery_type.replace(/_/g, " ")} />
              <SummaryField label="Recovery Status" value={<StatusBadge status={record.recovery_status} />} />
            </div>
          </DesktopCollapsibleSection>

          <DesktopCollapsibleSection id="equipment" title="Equipment / Service Details">
            <form id="maintenance-edit-form" action={updateMaintenanceRecord.bind(null, id)}>
              <EquipmentServiceFields
                trucks={trucks}
                trailers={trailers}
                defaultTruckId={record.truck_id}
                defaultTrailerId={record.trailer_id}
                defaultCost={record.cost}
                defaultServiceType={record.service_type}
                defaultVendorName={record.vendor_name}
                defaultOdometerReading={record.odometer_reading}
                defaultServiceDate={record.service_date}
                defaultNextServiceDueDate={record.next_service_due_date}
                defaultNextServiceDueOdometer={record.next_service_due_odometer}
                defaultDescription={record.description}
                costDisabled={locked}
              />
            </form>
            <div className="mt-3 flex items-center justify-between border-t border-desktop-border pt-3">
              <div className="flex items-center gap-2">
                {!isOutOfService ? (
                  <form action={setEquipmentStatusFromMaintenance.bind(null, record.truck_id, record.trailer_id, "in_maintenance")}>
                    <Button type="submit" size="sm" variant="outline">Mark Equipment In Maintenance</Button>
                  </form>
                ) : (
                  <form action={setEquipmentStatusFromMaintenance.bind(null, record.truck_id, record.trailer_id, "active")}>
                    <Button type="submit" size="sm" variant="outline">Mark Equipment Active</Button>
                  </form>
                )}
              </div>
              <Button type="submit" form="maintenance-edit-form">Save Changes</Button>
            </div>
          </DesktopCollapsibleSection>

          <DesktopCollapsibleSection id="payment" title="Payment & Responsibility">
            <PaymentResponsibilityFields
              drivers={driversRaw ?? []}
              defaultPaidBy={record.paid_by}
              defaultRecoveryType={record.recovery_type}
              defaultRecoverableAmount={record.recoverable_amount}
              defaultResponsibleDriverId={record.responsible_driver_id}
              formId="maintenance-edit-form"
              disabled={locked}
            />
            {locked && (
              <p className="mt-2 text-[11.5px] text-muted-foreground">
                Locked -- an expense and/or recovery already exists for this record. Payment &amp; Responsibility changes are saved together with Equipment/Service Details above only while unlocked.
              </p>
            )}
          </DesktopCollapsibleSection>

          <DesktopCollapsibleSection id="cost" title="Cost & Payment">
            <div className="grid grid-cols-2 gap-x-4 gap-y-2 text-[13px] sm:grid-cols-4">
              <SummaryField label="Repair Cost" value={money(record.cost)} />
              <SummaryField label="Paid By" value={record.paid_by.replace(/_/g, " ")} />
              <SummaryField label="Expense #" value={record.expense_id ? <Link href={`/expenses/${record.expense_id}`} className="text-primary hover:underline">View Expense</Link> : "-- none --"} />
              <SummaryField label="Recovery From" value={record.recovery_type.replace(/_/g, " ")} />
              <SummaryField label="Recoverable Amount" value={money(recovery?.recoverableAmount ?? 0)} />
              <SummaryField label="Recovered Amount" value={money(recovery?.recoveredAmount ?? 0)} />
              <SummaryField label="Remaining" value={money(recovery?.remainingAmount ?? 0)} />
              <SummaryField label="Recovery Status" value={<StatusBadge status={recovery?.recoveryStatus ?? "not_applicable"} />} />
            </div>
            {record.paid_by === "dispatch_company" && !record.expense_id && (
              <form action={createExpenseAction.bind(null, id)} className="mt-3 border-t border-desktop-border pt-3">
                <p className="mb-1.5 text-[11.5px] text-muted-foreground">
                  This creates exactly one company expense for this repair (category: Maintenance). If Recovery is set to a settlement, that expense stays as the ONE real company cost -- the settlement deduction is a recovery, not a second expense.
                </p>
                <Button type="submit" size="sm">Create Company Expense ({money(record.cost)})</Button>
              </form>
            )}
            {record.paid_by === "carrier" && (
              <p className="mt-3 border-t border-desktop-border pt-3 text-[11.5px] text-muted-foreground">
                Paid directly by the carrier -- this is an operational maintenance record only. No company expense and no settlement deduction apply.
              </p>
            )}
          </DesktopCollapsibleSection>

          <DesktopCollapsibleSection id="preventive" title="Preventive Maintenance">
            <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-[13px] sm:grid-cols-4">
              <SummaryField label="Next Service Due Date" value={record.next_service_due_date ? new Date(record.next_service_due_date + "T00:00:00").toLocaleDateString() : "--"} />
              <SummaryField label="Next Service Due Odometer" value={record.next_service_due_odometer != null ? record.next_service_due_odometer.toLocaleString() : "--"} />
              <SummaryField label="Current Odometer" value={record.truck_id && equipment ? ((equipment as { current_odometer?: number | null }).current_odometer?.toLocaleString() ?? "--") : "--"} />
              <SummaryField label="PM Status" value={PM_STATUS_LABEL[pmStatus]} />
            </div>
          </DesktopCollapsibleSection>

          <DesktopCollapsibleSection id="documents" title="Documents">
            {DOC_TYPES.map((d, i) => (
              <MaintenanceDocumentSlot key={d.type} maintenanceId={id} documentType={d.type} label={d.label} doc={documents[i]} />
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
