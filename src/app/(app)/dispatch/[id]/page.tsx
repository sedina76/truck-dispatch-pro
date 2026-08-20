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
import { FINANCIAL_ROLES, type OrgRole } from "@/lib/auth/require-role";

// Phase 2G.7 finding: the "Internal Financials"/"Rate Confirmation"/
// "Dispatch Notes" sections below were already labeled "STAFF ONLY --
// Never shown to drivers or carriers" (an earlier phase's intent), but
// nothing actually enforced it -- the dispatches row was select("*")'d
// and every section rendered unconditionally for every role. This is the
// same class of gap as Load Detail's Rate field; fixed the same way.
//
// Phase 2G.11: this is now the ONLY select used for `dispatches`,
// regardless of role -- load_rate/dispatch_fee_percentage/
// dispatch_fee_amount/carrier_net_amount/notes are no longer read from
// this table at all. 0068's writer cutover stopped populating them here
// (dispatch_financials/dispatch_internal_notes are authoritative now),
// so a role-gated `"*"` would have kept silently serving the stale
// pre-0068 (or, for any dispatch touched since, plain wrong -- frozen at
// the column default) values to owner/admin/dispatcher/accountant. See
// the financials/notesRow fetches below.
const DISPATCH_SAFE_COLUMNS =
  "id, organization_id, load_id, carrier_id, truck_id, driver_id, trailer_id, status, dispatched_at, completed_at, en_route_pickup_at, loaded_at, in_transit_at, delivered_at, cancelled_at, created_at, updated_at";

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

  const { data: roleData } = await supabase.rpc("current_role");
  const canSeeFinancials = FINANCIAL_ROLES.includes((roleData as OrgRole | null) ?? ("viewer" as OrgRole));

  const { data: dispatchRaw } = await supabase.from("dispatches").select(DISPATCH_SAFE_COLUMNS).eq("id", id).single();
  if (!dispatchRaw) notFound();
  const dispatch = dispatchRaw as unknown as {
    id: string;
    load_id: string;
    carrier_id: string;
    driver_id: string;
    truck_id: string;
    trailer_id: string | null;
    status: string;
  };

  const [summary, options, rateConDoc, financialsRes, notesRes] = await Promise.all([
    getLoadSummary(supabase, dispatch.load_id),
    getAssignmentOptions(supabase),
    // Rate Confirmation document itself is STAFF ONLY financial context
    // (same tier as everything else on this page) -- never fetched at all
    // for driver/viewer.
    canSeeFinancials ? getRateConfirmation(supabase, dispatch.load_id) : Promise.resolve(null),
    // Phase 2G.11: dispatch_financials is the sole authoritative source
    // for these 4 values (0068 writer cutover) -- fetched only when
    // canSeeFinancials, so the query for a protected row is never even
    // issued for driver/viewer (RLS would also block it, but there is no
    // reason to ask in the first place).
    canSeeFinancials
      ? supabase.from("dispatch_financials").select("load_rate, dispatch_fee_percentage, dispatch_fee_amount, carrier_net_amount").eq("dispatch_id", id).maybeSingle()
      : Promise.resolve({ data: null }),
    canSeeFinancials
      ? supabase.from("dispatch_internal_notes").select("notes").eq("dispatch_id", id).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);
  if (!summary) notFound();
  const financials = financialsRes.data;
  const notes = notesRes.data?.notes ?? null;

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
                  defaultFeePercentage={canSeeFinancials ? financials?.dispatch_fee_percentage : undefined}
                />
                <div className="max-w-xs">
                  <FormSelect label="Dispatch Status" name="status" defaultValue={dispatch.status} options={STATUS_OPTIONS} />
                </div>
              </div>
            </DesktopCollapsibleSection>

            {/* Phase 2G.7: these three sections were already labeled "STAFF
                ONLY -- never shown to drivers or carriers" but nothing
                enforced that label -- now actually gated, and (see
                DISPATCH_SAFE_COLUMNS above) the underlying values are
                absent from `dispatch` at all for driver/viewer, not just
                hidden here. */}
            {canSeeFinancials && (
              <DesktopCollapsibleSection id="financials" title="Internal Financials" description="Never shown to drivers or carriers" badge="STAFF ONLY" badgeTone="warning">
                <InternalFinancialsPanel
                  loadRate={Number(financials?.load_rate)}
                  feePercentage={Number(financials?.dispatch_fee_percentage)}
                  feeAmount={Number(financials?.dispatch_fee_amount)}
                  carrierNet={Number(financials?.carrier_net_amount)}
                />
                <Link href={`/loads/${dispatch.load_id}`} className="mt-2 inline-block text-[11.5px] font-medium text-primary hover:underline">
                  View full Profitability breakdown (revenue, all direct costs, margin) &rarr;
                </Link>
              </DesktopCollapsibleSection>
            )}

            {canSeeFinancials && (
              <DesktopCollapsibleSection id="rate_con" title="Rate Confirmation" description="Never shown to drivers or carriers" badge="STAFF ONLY" badgeTone="warning">
                <RateConfirmationIndicator doc={rateConDoc} loadId={dispatch.load_id} />
              </DesktopCollapsibleSection>
            )}

            {canSeeFinancials && (
              <DesktopCollapsibleSection id="notes" title="Dispatch Notes" description="Internal staff notes -- never shown to drivers or carriers" badge="STAFF ONLY" badgeTone="warning">
                <DispatchNotesField defaultValue={notes} />
                <p className="mt-1.5 text-[11px] text-desktop-text-muted">
                  Driver-visible trip instructions belong on the Load itself (Special Instructions), not here -- this field is never sent to the Driver Portal.
                </p>
              </DesktopCollapsibleSection>
            )}
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
