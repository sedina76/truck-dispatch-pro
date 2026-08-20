import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { FormField, FormSelect, FormGrid, FormTextarea } from "@/components/ui/form-field";
import { Button } from "@/components/ui/button";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import {
  DesktopCollapsibleSection,
  CollapsibleSectionsProvider,
  CollapsibleSectionsToolbar,
} from "@/components/desktop/collapsible-section";
import { AdditionalStopsFields } from "@/components/loads/additional-stops-fields";
import { RevenuePerMileLive } from "@/components/loads/rate-financials-fields";
import { createLoadWithStops } from "../create-actions";
import { getCurrentOrgId } from "@/lib/actions/records";
import { COMMON_TIMEZONES, isValidIanaTimezone } from "@/lib/timezone/iana";
import { FINANCIAL_ROLES, type OrgRole } from "@/lib/auth/require-role";

const EQUIPMENT_OPTIONS = [
  { value: "dry_van", label: "Dry Van" },
  { value: "reefer", label: "Reefer" },
  { value: "flatbed", label: "Flatbed" },
  { value: "step_deck", label: "Step Deck" },
  { value: "lowboy", label: "Lowboy" },
  { value: "tanker", label: "Tanker" },
  { value: "other", label: "Other" },
];

const STATUS_OPTIONS = [
  { value: "draft", label: "Draft" },
  { value: "posted", label: "Posted" },
  { value: "booked", label: "Booked" },
  { value: "dispatched", label: "Dispatched" },
  { value: "in_transit", label: "In Transit" },
  { value: "delivered", label: "Delivered" },
  { value: "cancelled", label: "Cancelled" },
];

const SECTION_DEFAULTS: Record<string, boolean> = {
  load_info: true,
  customer_broker: true,
  pickup: true,
  delivery: true,
  additional_stops: false,
  equipment_freight: false,
  internal_financials: false,
  rate_confirmation: false,
  references: false,
};

export default async function NewLoadPage() {
  const supabase = await createClient();
  const [{ data: brokers }, { data: customers }, { data: { user } }, { data: roleData }] = await Promise.all([
    supabase.from("brokers").select("id, company_name").order("company_name"),
    supabase.from("customers").select("id, company_name").order("company_name"),
    supabase.auth.getUser(),
    supabase.rpc("current_role"),
  ]);
  // Phase 2G.9 (item 3): no real financial VALUES are exposed by this
  // blank create form (RLS already blocks driver/viewer from submitting a
  // load at all), but the "STAFF ONLY" labeled sections below previously
  // rendered unconditionally like everywhere else audited this phase --
  // gated for UI/enforcement consistency with Load Detail and Dispatch
  // Detail, not because a data leak was found here.
  const canSeeFinancials = FINANCIAL_ROLES.includes((roleData as OrgRole | null) ?? ("viewer" as OrgRole));
  const { data: me } = user ? await supabase.from("profiles").select("full_name").eq("id", user.id).maybeSingle() : { data: null };

  // Default timezone for both stop sections (spec section 11): this
  // organization's own configured timezone, never the dispatcher's
  // browser timezone. Falls back to Central Time only if the org's own
  // value is somehow invalid (pre-Phase-2C.1 data).
  let orgTimezone = "America/Chicago";
  try {
    const orgId = await getCurrentOrgId();
    const { data: org } = await supabase.from("organizations").select("timezone").eq("id", orgId).maybeSingle();
    if (org?.timezone && isValidIanaTimezone(org.timezone)) orgTimezone = org.timezone;
  } catch {
    // No organization on this account yet -- form still renders with the fallback.
  }

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Loads", href: "/loads" }, { label: "New Load", href: "/loads/new" }]} />

      <form action={createLoadWithStops} className="space-y-3">
        <CollapsibleSectionsProvider defaults={SECTION_DEFAULTS}>
          <div className="flex items-center justify-between">
            <div>
              <h1 className="text-base font-semibold text-desktop-text">New Load</h1>
              <p className="text-[12px] text-desktop-text-muted">Book pickup, delivery, and rate details from one screen.</p>
            </div>
            <CollapsibleSectionsToolbar />
          </div>

          <div className="space-y-3">
            <DesktopCollapsibleSection id="load_info" title="Load Information">
              <FormGrid>
                <FormField label="Load Number" name="load_number" required placeholder="LD-100004" />
                <FormSelect label="Status" name="status" defaultValue="draft" options={STATUS_OPTIONS} />
                <div className="space-y-1">
                  <label className="text-[12px] font-medium text-desktop-text">Dispatcher / Booked By</label>
                  <div className="flex h-8 items-center rounded-sm border border-desktop-border bg-desktop-muted px-2.5 text-[13px] text-desktop-text-muted">
                    {me?.full_name ?? "You"} (recorded automatically)
                  </div>
                </div>
              </FormGrid>
            </DesktopCollapsibleSection>

            <DesktopCollapsibleSection id="customer_broker" title="Customer / Broker" description="Brokered load OR direct customer load">
              <FormGrid>
                <FormSelect label="Broker (if brokered)" name="broker_id" options={(brokers ?? []).map((b) => ({ value: b.id, label: b.company_name }))} />
                <FormSelect label="Customer (if direct)" name="customer_id" options={(customers ?? []).map((c) => ({ value: c.id, label: c.company_name }))} />
                <FormField label="Rate Confirmation #" name="rate_confirmation_number" />
              </FormGrid>
              <p className="mt-2 text-[11.5px] text-desktop-text-muted">
                Select a broker for a brokered load, or a customer for a load booked directly. If your workflow treats broker as
                authoritative, the broker set here takes precedence, matching the rest of the app.
              </p>
            </DesktopCollapsibleSection>

            <StopSection sectionId="pickup" title="Pickup" prefix="pickup" defaultTimezone={orgTimezone} />
            <StopSection sectionId="delivery" title="Delivery" prefix="delivery" defaultTimezone={orgTimezone} />

            <DesktopCollapsibleSection id="additional_stops" title="Additional Stops" description="Multi-stop loads">
              <AdditionalStopsFields defaultTimezone={orgTimezone} />
            </DesktopCollapsibleSection>

            <DesktopCollapsibleSection id="equipment_freight" title="Equipment & Freight">
              <FormGrid>
                <FormSelect label="Equipment Type" name="equipment_type" options={EQUIPMENT_OPTIONS} />
                <FormField label="Commodity" name="commodity" />
                <FormField label="Weight (lbs)" name="weight_lbs" type="number" />
                <FormField label="Total Miles" name="total_miles" type="number" step="0.1" />
              </FormGrid>
            </DesktopCollapsibleSection>

            {canSeeFinancials && (
              <DesktopCollapsibleSection id="internal_financials" title="Internal Rate & Financials" description="Internal staff information -- never shown to drivers or carriers" badge="STAFF ONLY" badgeTone="warning">
                <FormGrid>
                  <FormField label="Customer / Broker Rate ($)" name="rate" type="number" step="0.01" required />
                  <RevenuePerMileLive />
                </FormGrid>
                <p className="mt-2 text-[11.5px] text-desktop-text-muted">
                  Transportation cost and margin are calculated on the Load Detail page&apos;s Profitability section once this load has
                  a dispatch and any settlement/expense data -- shown here would be a fabricated estimate before that exists.
                </p>
              </DesktopCollapsibleSection>
            )}

            {canSeeFinancials && (
              <DesktopCollapsibleSection id="rate_confirmation" title="Rate Confirmation Document" description="Internal staff information -- never shown to drivers or carriers" badge="STAFF ONLY" badgeTone="warning">
                <div className="space-y-1">
                  <label className="text-[12px] font-medium text-desktop-text">Upload Rate Confirmation</label>
                  <input
                    type="file"
                    name="rate_confirmation_file"
                    accept=".pdf,.jpg,.jpeg,.png"
                    className="block w-full text-[12px] text-desktop-text-muted file:mr-2 file:rounded-sm file:border-0 file:bg-primary file:px-3 file:py-1.5 file:text-[12px] file:font-medium file:text-primary-foreground"
                  />
                  <p className="text-[11px] text-desktop-text-muted">PDF, JPG, or PNG, up to 15 MB. Stored privately -- only accessible to staff via short-lived signed links.</p>
                </div>
              </DesktopCollapsibleSection>
            )}

            <DesktopCollapsibleSection id="references" title="References & Instructions">
              <FormGrid>
                <FormTextarea label="Special Instructions" name="special_instructions" />
              </FormGrid>
            </DesktopCollapsibleSection>
          </div>
        </CollapsibleSectionsProvider>

        <div className="flex items-center justify-end gap-2 border-t border-desktop-border pt-3">
          <Link href="/loads" className="inline-flex h-8 items-center rounded-sm px-3 text-[13px] font-medium text-muted-foreground transition-colors hover:bg-muted">
            Cancel
          </Link>
          <Button type="submit">Create Load</Button>
        </div>
      </form>
    </div>
  );
}

function StopSection({ sectionId, title, prefix, defaultTimezone }: { sectionId: string; title: string; prefix: "pickup" | "delivery"; defaultTimezone: string }) {
  return (
    <DesktopCollapsibleSection id={sectionId} title={title}>
      <FormGrid>
        <div className="space-y-1 sm:col-span-2">
          <label className="text-[12px] font-medium text-desktop-text">Facility / Company Name</label>
          <input name={`${prefix}_facility_name`} className="h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20" />
        </div>
        <div className="space-y-1 sm:col-span-2">
          <label className="text-[12px] font-medium text-desktop-text">Address</label>
          <input name={`${prefix}_address_line1`} className="h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20" />
        </div>
        <div className="space-y-1">
          <label className="text-[12px] font-medium text-desktop-text">Address Line 2</label>
          <input name={`${prefix}_address_line2`} className="h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20" />
        </div>
        <div className="grid grid-cols-3 gap-2.5">
          <div className="space-y-1">
            <label className="text-[12px] font-medium text-desktop-text">
              City <span className="text-danger">*</span>
            </label>
            <input name={`${prefix}_city`} required className="h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20" />
          </div>
          <div className="space-y-1">
            <label className="text-[12px] font-medium text-desktop-text">
              State <span className="text-danger">*</span>
            </label>
            <input name={`${prefix}_state`} required maxLength={2} className="h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20" />
          </div>
          <div className="space-y-1">
            <label className="text-[12px] font-medium text-desktop-text">ZIP</label>
            <input name={`${prefix}_postal_code`} className="h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20" />
          </div>
        </div>
        <FormField label="Contact Name" name={`${prefix}_contact_name`} />
        <FormField label="Contact Phone" name={`${prefix}_contact_phone`} type="tel" />
        <FormField label={`${title} Date`} name={`${prefix}_date`} type="date" required />
        <FormField label="Appointment Time" name={`${prefix}_time`} type="time" />
        <FormField label="Appointment Window End (optional)" name={`${prefix}_window_end`} type="time" />
        <FormSelect label="Timezone" name={`${prefix}_timezone`} defaultValue={defaultTimezone} options={COMMON_TIMEZONES} />
        <FormField label={`${title} Number / Reference`} name={`${prefix}_reference_number`} />
        <FormTextarea label="Notes" name={`${prefix}_notes`} />
      </FormGrid>
    </DesktopCollapsibleSection>
  );
}
