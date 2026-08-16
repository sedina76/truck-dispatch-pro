import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { StatusBadge } from "@/components/ui/status-badge";
import { FormSelect } from "@/components/ui/form-field";
import { DispatchNotesField } from "@/components/dispatch/dispatch-notes-field";
import { Button } from "@/components/ui/button";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopCollapsibleSection, CollapsibleSectionsProvider, CollapsibleSectionsToolbar } from "@/components/desktop/collapsible-section";
import { LoadSummaryPanel, TripStopsPanel } from "@/components/dispatch/load-summary-trip";
import { AssignmentFields } from "@/components/dispatch/assignment-fields";
import { InternalFinancialsPanel } from "@/components/dispatch/internal-financials-panel";
import { RateConfirmationIndicator } from "@/components/dispatch/rate-confirmation-indicator";
import { CancelDispatchForm } from "@/components/dispatch/cancel-dispatch-form";
import { DispatchForm } from "@/components/dispatch/dispatch-form";
import { DispatchConflictAlert } from "@/components/dispatch/dispatch-conflict-alert";
import { getLoadSummary, getAssignmentOptions, getRateConfirmation } from "../dispatch-data";
import { updateDispatch, cancelDispatch } from "../actions";

const STATUS_OPTIONS = [
  { value: "assigned", label: "Assigned" },
  { value: "accepted", label: "Accepted" },
  { value: "en_route_to_pickup", label: "En Route to Pickup" },
  { value: "at_pickup", label: "At Pickup" },
  { value: "loaded", label: "Loaded" },
  { value: "en_route_to_delivery", label: "En Route to Delivery" },
  { value: "at_delivery", label: "At Delivery" },
  { value: "delivered", label: "Delivered" },
  { value: "completed", label: "Completed" },
  { value: "cancelled", label: "Cancelled" },
];

const SECTION_DEFAULTS: Record<string, boolean> = {
  load_summary: true,
  trip: true,
  assignment: true,
  financials: false,
  rate_con: false,
  notes: false,
};

export default async function DispatchDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: dispatch } = await supabase.from("dispatches").select("*").eq("id", id).single();
  if (!dispatch) notFound();

  const [summary, options, rateConDoc] = await Promise.all([
    getLoadSummary(supabase, dispatch.load_id),
    getAssignmentOptions(supabase),
    getRateConfirmation(supabase, dispatch.load_id),
  ]);
  if (!summary) notFound();

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Dispatch Board", href: "/dispatch/board" }, { label: summary.load.load_number, href: `/dispatch/${id}` }]} />

      {dispatch.status === "cancelled" && (
        <div className="rounded-lg border border-desktop-border bg-desktop-muted px-3.5 py-2.5 text-[13px] text-desktop-text">
          This dispatch is cancelled. The load has been returned to Booked status where applicable.
        </div>
      )}

      {/* id + a `form` attribute on the Save button below, rather than
          nesting the bottom action bar inside this <form> -- CancelDispatchForm
          renders its own <form>, and HTML forbids nested forms (this was
          causing a hydration error). Same "Save button submits via the
          form attribute" convention FormCard already uses elsewhere. */}
      <DispatchForm id="dispatch-edit-form" action={updateDispatch.bind(null, id)} className="space-y-3">
        <CollapsibleSectionsProvider defaults={SECTION_DEFAULTS}>
          <div className="flex items-center justify-between">
            <div>
              <h1 className="text-base font-semibold text-desktop-text">Dispatch -- {summary.load.load_number}</h1>
              <p className="mt-0.5 flex items-center gap-1.5 text-[12px] text-desktop-text-muted">
                Status: <StatusBadge status={dispatch.status} />
              </p>
            </div>
            <CollapsibleSectionsToolbar />
          </div>

          <DispatchConflictAlert />

          <div className="space-y-3">
            <DesktopCollapsibleSection id="load_summary" title="Load Summary">
              <LoadSummaryPanel load={summary.load} />
            </DesktopCollapsibleSection>

            <DesktopCollapsibleSection id="trip" title="Trip / Stops">
              <TripStopsPanel stops={summary.stops} />
            </DesktopCollapsibleSection>

            <DesktopCollapsibleSection id="assignment" title="Assignment">
              <div className="space-y-3">
                <AssignmentFields
                  carriers={options.carriers}
                  drivers={options.drivers}
                  trucks={options.trucks}
                  trailers={options.trailers}
                  defaultCarrierId={dispatch.carrier_id}
                  defaultDriverId={dispatch.driver_id}
                  defaultTruckId={dispatch.truck_id}
                  defaultTrailerId={dispatch.trailer_id}
                  defaultFeePercentage={dispatch.dispatch_fee_percentage}
                />
                <div className="max-w-xs">
                  <FormSelect label="Dispatch Status" name="status" defaultValue={dispatch.status} options={STATUS_OPTIONS} />
                </div>
              </div>
            </DesktopCollapsibleSection>

            <DesktopCollapsibleSection id="financials" title="Internal Financials" description="Never shown to drivers or carriers" badge="STAFF ONLY" badgeTone="warning">
              <InternalFinancialsPanel
                loadRate={Number(dispatch.load_rate)}
                feePercentage={Number(dispatch.dispatch_fee_percentage)}
                feeAmount={Number(dispatch.dispatch_fee_amount)}
                carrierNet={Number(dispatch.carrier_net_amount)}
              />
              <Link href={`/loads/${dispatch.load_id}`} className="mt-2 inline-block text-[11.5px] font-medium text-primary hover:underline">
                View full Profitability breakdown (revenue, all direct costs, margin) &rarr;
              </Link>
            </DesktopCollapsibleSection>

            <DesktopCollapsibleSection id="rate_con" title="Rate Confirmation" description="Never shown to drivers or carriers" badge="STAFF ONLY" badgeTone="warning">
              <RateConfirmationIndicator doc={rateConDoc} loadId={dispatch.load_id} />
            </DesktopCollapsibleSection>

            <DesktopCollapsibleSection id="notes" title="Dispatch Notes" description="Internal staff notes -- never shown to drivers or carriers" badge="STAFF ONLY" badgeTone="warning">
              <DispatchNotesField defaultValue={dispatch.notes} />
              <p className="mt-1.5 text-[11px] text-desktop-text-muted">
                Driver-visible trip instructions belong on the Load itself (Special Instructions), not here -- this field is never sent to the Driver Portal.
              </p>
            </DesktopCollapsibleSection>
          </div>
        </CollapsibleSectionsProvider>
      </DispatchForm>

      <div className="flex items-center justify-between border-t border-desktop-border pt-3">
        <div>{dispatch.status !== "cancelled" && <CancelDispatchForm action={cancelDispatch.bind(null, id)} />}</div>
        <div className="flex items-center gap-2">
          <Link href="/dispatch/board" className="inline-flex h-8 items-center rounded-sm px-3 text-[13px] font-medium text-muted-foreground transition-colors hover:bg-muted">
            Back to Board
          </Link>
          <Button type="submit" form="dispatch-edit-form">Save Changes</Button>
        </div>
      </div>
    </div>
  );
}
