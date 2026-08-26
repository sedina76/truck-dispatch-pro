import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { SectionHeading } from "@/components/ui/section-heading";
import { updateOrganization, updateExceptionEscalationSettings } from "../actions";
import { COMMON_TIMEZONES } from "@/lib/timezone/iana";

const AUTHORITY_OPTIONS = [
  { value: "active", label: "Active" },
  { value: "pending", label: "Pending" },
  { value: "inactive", label: "Inactive" },
  { value: "revoked", label: "Revoked" },
];

const AUTOMATION_MODE_OPTIONS = [
  { value: "off", label: "Off -- no GPS status automation" },
  { value: "suggest", label: "Suggest -- driver confirms before status changes (recommended)" },
  { value: "automatic", label: "Automatic -- eligible transitions apply immediately" },
];

export default async function OrganizationSettingsPage() {
  const supabase = await createClient();
  const orgId = await getCurrentOrgId();
  const { data: org } = await supabase.from("organizations").select("*").eq("id", orgId).single();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: profile } = await supabase.from("profiles").select("role").eq("id", user!.id).single();
  const isOwner = profile?.role === "owner";
  // Phase 2P.6B -- exception escalation settings are Owner/Admin, wider
  // than this page's own Owner-only convention (isOwner above) -- kept as
  // its own separate permission check/FormCard rather than folded into
  // the isOwner-gated fieldset below.
  const isOwnerOrAdmin = profile?.role === "owner" || profile?.role === "admin";

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div />
        <Link href="/settings/organization/bank-accounts" className="text-sm font-medium text-primary hover:underline">
          Manage Bank Accounts &rarr;
        </Link>
      </div>

      <FormCard
        title="Company"
        description={
          isOwner
            ? "Legal identity, authorities, and invoicing defaults for your organization."
            : "Legal identity, authorities, and invoicing defaults. Only the owner can make changes."
        }
        action={updateOrganization}
        cancelHref="/dashboard"
        submitLabel="Save Changes"
      >
        <fieldset disabled={!isOwner} className="contents">
          <FormGrid>
            <SectionHeading title="Company Profile" description="Legal name and how customers reach you." />
            <FormField label="Company name" name="name" defaultValue={org?.name} required />
            <FormField label="DBA name" name="dba_name" defaultValue={org?.dba_name} />
            <FormField label="MC number" name="mc_number" defaultValue={org?.mc_number} />
            <FormField label="DOT number" name="dot_number" defaultValue={org?.dot_number} />
            <FormField label="EIN" name="ein" defaultValue={org?.ein} placeholder="12-3456789" />
            <FormField label="Business phone" name="business_phone" type="tel" defaultValue={org?.business_phone} />
            <FormField label="Fax" name="fax" type="tel" defaultValue={org?.fax} />
            <FormField label="Business email" name="business_email" type="email" defaultValue={org?.business_email} />
            <FormField label="Website" name="website" defaultValue={org?.website} placeholder="https://" />

            <SectionHeading title="Physical Address" description="Your terminal or primary place of business." />
            <FormField label="Address" name="address_line1" defaultValue={org?.address_line1} />
            <FormField label="City" name="city" defaultValue={org?.city} />
            <FormField label="State" name="state" defaultValue={org?.state} />
            <FormField label="Postal code" name="postal_code" defaultValue={org?.postal_code} />

            <SectionHeading title="Mailing Address" description="Where paper checks and correspondence should go, if different." />
            <FormField label="Mailing address" name="mailing_address_line1" defaultValue={org?.mailing_address_line1} />
            <FormField label="Mailing city" name="mailing_city" defaultValue={org?.mailing_city} />
            <FormField label="Mailing state" name="mailing_state" defaultValue={org?.mailing_state} />
            <FormField label="Mailing postal code" name="mailing_postal_code" defaultValue={org?.mailing_postal_code} />

            <SectionHeading title="Authorities & Safety" description="FMCSA operating authority status." />
            <FormSelect
              label="USDOT authority"
              name="usdot_authority_status"
              defaultValue={org?.usdot_authority_status}
              options={AUTHORITY_OPTIONS}
            />
            <FormSelect
              label="Broker authority"
              name="broker_authority_status"
              defaultValue={org?.broker_authority_status}
              options={AUTHORITY_OPTIONS}
            />
            <FormSelect
              label="Dispatch authority"
              name="dispatch_authority_status"
              defaultValue={org?.dispatch_authority_status}
              options={AUTHORITY_OPTIONS}
            />
            <FormField label="Safety rating" name="safety_rating" defaultValue={org?.safety_rating} placeholder="Satisfactory" />
            <FormField label="Safety rating date" name="safety_rating_date" type="date" defaultValue={org?.safety_rating_date} />

            <SectionHeading title="Invoicing Defaults" description="Applied to every new invoice unless overridden." />
            <FormField
              label="Default payment terms (days)"
              name="default_payment_terms_days"
              type="number"
              defaultValue={org?.default_payment_terms_days ?? 30}
            />
            <FormTextarea label="Invoice footer" name="invoice_footer" defaultValue={org?.invoice_footer} />
            <FormTextarea label="Default invoice notes" name="default_invoice_notes" defaultValue={org?.default_invoice_notes} />

            <SectionHeading
              title="Timezone"
              description="Used as the default timezone for new stop appointments that don't specify their own, and as the fallback display timezone for existing stops that predate per-stop timezones (spec Phase 2C.1). Changing this never rewrites any stop's stored appointment time -- only which zone is used as a fallback."
            />
            <FormSelect label="Organization timezone" name="timezone" defaultValue={org?.timezone ?? "America/Chicago"} options={COMMON_TIMEZONES} required />

            <SectionHeading
              title="GPS Tracking & Detention"
              description="Geofence radius, automation, and free-time settings used by driver phone GPS (Phase 2A/2B). Display/calculation only -- no automatic billing."
            />
            <FormField
              label="Pickup detention free time (minutes)"
              name="pickup_detention_free_minutes"
              type="number"
              defaultValue={org?.pickup_detention_free_minutes ?? 120}
            />
            <FormField
              label="Delivery detention free time (minutes)"
              name="delivery_detention_free_minutes"
              type="number"
              defaultValue={org?.delivery_detention_free_minutes ?? 120}
            />
            <FormField
              label="Pickup geofence radius (meters)"
              name="pickup_geofence_radius_m"
              type="number"
              defaultValue={org?.pickup_geofence_radius_m ?? 300}
            />
            <FormField
              label="Delivery geofence radius (meters)"
              name="delivery_geofence_radius_m"
              type="number"
              defaultValue={org?.delivery_geofence_radius_m ?? 300}
            />
            <FormSelect
              label="GPS automation mode"
              name="gps_automation_mode"
              defaultValue={org?.gps_automation_mode ?? "suggest"}
              options={AUTOMATION_MODE_OPTIONS}
            />

            <SectionHeading
              title="Route Deviation Monitoring"
              description="Flags a dispatch as OFF ROUTE when a truck's GPS is sustainedly, materially away from its calculated route -- not a single noisy ping. Off by default for every organization; turn on once you're comfortable with the thresholds below (Phase 2D)."
            />
            <div className="space-y-1">
              <label className="flex items-center gap-2 text-[13px] font-medium text-desktop-text">
                <input type="checkbox" name="route_deviation_enabled" defaultChecked={org?.route_deviation_enabled ?? false} className="size-4 rounded border-border" />
                Route Deviation Monitoring enabled
              </label>
            </div>
            <FormField
              label="Warning distance (miles)"
              name="route_deviation_warning_mi"
              type="number"
              step="0.05"
              defaultValue={org?.route_deviation_warning_m != null ? Math.round((org.route_deviation_warning_m / 1609.344) * 100) / 100 : 0.5}
            />
            <FormField
              label="Confirmed deviation distance (miles)"
              name="route_deviation_confirmed_mi"
              type="number"
              step="0.05"
              defaultValue={org?.route_deviation_confirmed_m != null ? Math.round((org.route_deviation_confirmed_m / 1609.344) * 100) / 100 : 1.0}
            />
            <FormField
              label="Recovery distance (miles)"
              name="route_deviation_recovery_mi"
              type="number"
              step="0.05"
              defaultValue={org?.route_deviation_recovery_m != null ? Math.round((org.route_deviation_recovery_m / 1609.344) * 100) / 100 : 0.25}
            />
          </FormGrid>
        </fieldset>
      </FormCard>

      {/* Phase 2P.6B -- separate FormCard, separate action, separate
          permission (Owner/Admin -- wider than the isOwner-only fieldset
          above), separate table columns (0107). Deliberately not folded
          into the big form above, so this feature's own permission model
          never collides with the rest of this page's Owner-only
          convention. */}
      <FormCard
        title="Exception Escalation"
        description="Notifies Owner/Admin/Dispatcher when a critical or high-severity operational exception (route, detention, GPS, compliance, insurance) has gone unaddressed too long. Acknowledging an exception stops escalation for it -- it does not need to be resolved first. Leave a field blank to disable escalation for that severity; every organization starts disabled until configured here."
        action={updateExceptionEscalationSettings}
        cancelHref="/settings/organization"
      >
        <fieldset disabled={!isOwnerOrAdmin} className="contents">
          <FormGrid>
            <FormField
              label="Critical exception escalation (minutes)"
              name="critical_exception_escalation_minutes"
              type="number"
              placeholder="Disabled"
              defaultValue={org?.critical_exception_escalation_minutes ?? undefined}
            />
            <FormField
              label="High exception escalation (minutes)"
              name="high_exception_escalation_minutes"
              type="number"
              placeholder="Disabled"
              defaultValue={org?.high_exception_escalation_minutes ?? undefined}
            />
          </FormGrid>
        </fieldset>
      </FormCard>
    </div>
  );
}
