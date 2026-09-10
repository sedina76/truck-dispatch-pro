import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { FormSelect } from "@/components/ui/form-field";
import { DispatchNotesField } from "@/components/dispatch/dispatch-notes-field";
import { Button } from "@/components/ui/button";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopCollapsibleSection, CollapsibleSectionsProvider, CollapsibleSectionsToolbar } from "@/components/desktop/collapsible-section";
import { LoadSummaryPanel, TripStopsPanel } from "@/components/dispatch/load-summary-trip";
import { AssignmentFields } from "@/components/dispatch/assignment-fields";
import { InternalFinancialsPanel } from "@/components/dispatch/internal-financials-panel";
import { RateConfirmationIndicator } from "@/components/dispatch/rate-confirmation-indicator";
import { DispatchForm } from "@/components/dispatch/dispatch-form";
import { DispatchConflictAlert } from "@/components/dispatch/dispatch-conflict-alert";
import { getLoadSummary, getAssignmentOptions, getRateConfirmation } from "../dispatch-data";
import { createDispatch } from "../actions";
import { ACTIVE_DISPATCH_STATUSES } from "@/lib/dispatch/conflicts";
import { FINANCIAL_ROLES, type OrgRole } from "@/lib/auth/require-role";

const SECTION_DEFAULTS: Record<string, boolean> = {
  load_summary: true,
  trip: true,
  assignment: true,
  financials: false,
  rate_con: false,
  notes: false,
};

export default async function NewDispatchPage({ searchParams }: { searchParams: Promise<{ load_id?: string }> }) {
  const { load_id } = await searchParams;
  const supabase = await createClient();

  const { data: roleData } = await supabase.rpc("current_role");
  const canSeeFinancials = FINANCIAL_ROLES.includes((roleData as OrgRole | null) ?? ("viewer" as OrgRole));

  // Step 1: no load chosen yet -- a plain GET selector, no assignment UI
  // rendered until a specific load is in scope (spec section 2: verify the
  // trip before assigning equipment). Phase 2G.9: rate is only requested/
  // shown in the picker label for financial roles -- this was a real gap
  // (Dispatch is Operations, open to every role).
  if (!load_id) {
    // Phase 2G.12: `rate` dropped from this select -- load_financials is
    // authoritative now (0068 writer cutover). Merged in below, fetched
    // only for canSeeFinancials (unchanged from the 2G.9 gating already
    // here -- only the SOURCE changes).
    // Only loads that are NOT already on an active dispatch -- so the picker
    // and the server-side conflict check (checkAssignmentConflicts, which
    // now rejects a load that already has an active dispatch) agree, and a
    // dispatcher is never invited to duplicate-dispatch a load.
    const [{ data: loadsData }, { data: activeDispatchRows }] = await Promise.all([
      supabase.from("loads").select("id, load_number").in("status", ["draft", "posted", "booked"]).order("load_number"),
      supabase.from("dispatches").select("load_id").in("status", ACTIVE_DISPATCH_STATUSES),
    ]);
    const dispatchedLoadIds = new Set((activeDispatchRows ?? []).map((d) => d.load_id));
    const loads = ((loadsData ?? []) as { id: string; load_number: string }[]).filter((l) => !dispatchedLoadIds.has(l.id));
    const rateByLoadId = new Map<string, number>();
    if (canSeeFinancials && loads.length > 0) {
      const { data: lf } = await supabase.from("load_financials").select("load_id, rate").in("load_id", loads.map((l) => l.id));
      for (const row of lf ?? []) rateByLoadId.set(row.load_id, Number(row.rate));
    }

    return (
      <div className="space-y-3">
        <DesktopWorkspaceTabs tabs={[{ label: "Dispatch Board", href: "/dispatch/board" }, { label: "New Dispatch", href: "/dispatch/new" }]} />
        <div className="max-w-md rounded-md border border-desktop-border bg-desktop-panel p-4">
          <h1 className="text-base font-semibold text-desktop-text">New Dispatch</h1>
          <p className="mt-1 text-[12.5px] text-desktop-text-muted">Select a load to assign a carrier, driver, and truck to.</p>
          <form action="/dispatch/new" method="GET" className="mt-3 space-y-3">
            <FormSelect
              label="Load"
              name="load_id"
              required
              options={loads.map((l) => ({
                value: l.id,
                label: canSeeFinancials ? `${l.load_number} -- $${(rateByLoadId.get(l.id) ?? 0).toLocaleString()}` : l.load_number,
              }))}
            />
            <Button type="submit">Continue</Button>
          </form>
          {loads.length === 0 && (
            <p className="mt-3 text-[12.5px] text-desktop-text-muted">
              No undispatched loads available. <Link href="/loads/new" className="font-medium text-primary hover:underline">Book a load</Link> first.
            </p>
          )}
        </div>
      </div>
    );
  }

  const [summary, options, rateConDoc] = await Promise.all([
    getLoadSummary(supabase, load_id),
    getAssignmentOptions(supabase),
    canSeeFinancials ? getRateConfirmation(supabase, load_id) : Promise.resolve(null),
  ]);

  if (!summary) {
    return (
      <div className="space-y-3">
        <DesktopWorkspaceTabs tabs={[{ label: "Dispatch Board", href: "/dispatch/board" }, { label: "New Dispatch", href: "/dispatch/new" }]} />
        <p className="text-sm text-desktop-text-muted">
          That load couldn&apos;t be found. <Link href="/dispatch/new" className="font-medium text-primary hover:underline">Choose a different load</Link>.
        </p>
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Dispatch Board", href: "/dispatch/board" }, { label: "New Dispatch", href: "/dispatch/new" }]} />

      <DispatchForm action={createDispatch} className="space-y-3">
        <input type="hidden" name="load_id" value={load_id} />
        <CollapsibleSectionsProvider defaults={SECTION_DEFAULTS}>
          <div className="flex items-center justify-between">
            <div>
              <h1 className="text-base font-semibold text-desktop-text">New Dispatch -- {summary.load.load_number}</h1>
              <p className="text-[12px] text-desktop-text-muted">
                <Link href="/dispatch/new" className="text-primary hover:underline">Choose a different load</Link>
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
              <AssignmentFields carriers={options.carriers} drivers={options.drivers} trucks={options.trucks} trailers={options.trailers} />
            </DesktopCollapsibleSection>

            {canSeeFinancials && (
              <DesktopCollapsibleSection id="financials" title="Internal Financials" description="Never shown to drivers or carriers" badge="STAFF ONLY" badgeTone="warning">
                <InternalFinancialsPanel loadRate={null} feePercentage={10} feeAmount={null} carrierNet={null} />
              </DesktopCollapsibleSection>
            )}

            {canSeeFinancials && (
              <DesktopCollapsibleSection id="rate_con" title="Rate Confirmation" description="Never shown to drivers or carriers" badge="STAFF ONLY" badgeTone="warning">
                <RateConfirmationIndicator doc={rateConDoc} loadId={load_id} />
              </DesktopCollapsibleSection>
            )}

            {canSeeFinancials && (
              <DesktopCollapsibleSection id="notes" title="Dispatch Notes" description="Internal staff notes -- never shown to drivers or carriers" badge="STAFF ONLY" badgeTone="warning">
                <DispatchNotesField />
                <p className="mt-1.5 text-[11px] text-desktop-text-muted">
                  Driver-visible trip instructions belong on the Load itself (Special Instructions), not here -- this field is never sent to the Driver Portal.
                </p>
              </DesktopCollapsibleSection>
            )}
          </div>
        </CollapsibleSectionsProvider>

        <div className="flex items-center justify-end gap-2 border-t border-desktop-border pt-3">
          <Link href="/dispatch/board" className="inline-flex h-8 items-center rounded-sm px-3 text-[13px] font-medium text-muted-foreground transition-colors hover:bg-muted">
            Cancel
          </Link>
          <Button type="submit">Create Dispatch</Button>
        </div>
      </DispatchForm>
    </div>
  );
}
