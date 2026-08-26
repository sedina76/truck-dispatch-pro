import Link from "next/link";
import { notFound } from "next/navigation";
import { ShieldCheck, Radio } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { ConfirmDeleteForm } from "@/components/ui/confirm-delete-form";
import { Button } from "@/components/ui/button";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { RevealPiiButton } from "@/components/ui/reveal-pii-button";
import { SetPiiForm } from "@/components/ui/set-pii-form";
import { PortalAccessForm } from "@/components/drivers/portal-access-form";
import { DriverTripHistorySection } from "@/components/drivers/trip-history-section";
import { DriverPaySection } from "@/components/drivers/driver-pay-section";
import { DriverSettlementSummarySection } from "@/components/drivers/driver-settlement-summary-section";
import { DriverProfitabilitySection } from "@/components/drivers/driver-profitability-section";
import { DriverExpenseSummarySection } from "@/components/drivers/driver-expense-summary-section";
import { ShareExternalProfileSection } from "@/components/loads/share-external-profile-section";
import type { DateRangeKey } from "@/lib/drivers/trip-metrics";
import { updateDriver, setDriverPii, revealDriverPii, setDriverPortalPin, revokeDriverPortalAccess } from "../actions";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import {
  CollapsibleSectionsProvider,
  CollapsibleSectionsToolbar,
  DesktopCollapsibleSection,
} from "@/components/desktop/collapsible-section";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";
import { FINANCIAL_ROLES, type OrgRole } from "@/lib/auth/require-role";
import { workerTypeRequiresW9, DRIVER_W9_STAFF_SAFE_SELECT, type DriverWorkerType, type DriverW9Row } from "@/lib/driver-w9/types";
import { DriverW9Card } from "../applications/[id]/driver-w9-card";

// Section ids + default open/closed state (spec: Employment and Personal
// Information start open, everything else starts closed; Sensitive
// Information MUST default closed). Expand All / Collapse All only ever
// toggles exactly these ids -- see CollapsibleSectionsProvider.
const SECTION_DEFAULTS: Record<string, boolean> = {
  employment: true,
  personal: true,
  cdl: false,
  medical_compliance: false,
  work_auth: false,
  payroll: false,
  notes: false,
  trip_history: false,
  portal_access: false,
  settlement_summary: false,
  driver_pay: false,
  profitability: false,
  company_expenses: false,
  share_profile: false,
  sensitive: false,
};

// Compliance badge: a real (never fabricated) count of this driver's own
// expiry-date fields that are already expired or expiring within 30 days.
// Uses only data already fetched for the page -- no extra query.
function expiringCount(driver: Record<string, unknown>): number {
  const fields = ["cdl_expiry_date", "medical_card_expiry_date", "drug_test_expiry_date", "twic_expiry_date", "hazmat_endorsement_expiry_date"];
  const soon = new Date();
  soon.setDate(soon.getDate() + 30);
  const cutoff = soon.toISOString().slice(0, 10);
  return fields.filter((f) => {
    const v = driver[f];
    return typeof v === "string" && v <= cutoff;
  }).length;
}

export default async function DriverDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ range?: string; from?: string; to?: string }>;
}) {
  const { id } = await params;
  const { range, from, to } = await searchParams;
  const supabase = await createClient();

  // Explicit column list, not select("*"): the three encrypted PII columns
  // (ssn_encrypted, direct_deposit_account_encrypted, direct_deposit_routing_encrypted)
  // are deliberately excluded from the authenticated grant (migration 0014)
  // so they can only ever be read through reveal_driver_pii(). select("*")
  // asks for them anyway, which Postgres denies for the whole query -- not
  // just those columns -- which .single() turns into "no data", which
  // notFound() turns into a misleading 404 for every driver.
  // Phase 2G.12 finding: the Payroll section below (pay_type/pay_rate) had
  // NO canSeeFinancials gate at all -- rendered unconditionally for every
  // role, including driver/viewer. driver_compensation is also the
  // authoritative source now (2G.10 writer cutover moved pay_type/pay_rate
  // there); dropped from this always-fetched select and moved to a
  // separate, canSeeFinancials-gated query below, matching "do not fetch
  // protected financial rows for driver/viewer" -- not just hidden in JSX.
  const [{ data: driver }, { data: carriers }, { data: user }, { data: portalCredential }, tripCountRes] = await Promise.all([
    supabase
      .from("drivers")
      .select(
        `id, organization_id, carrier_id, first_name, middle_name, last_name, phone, email,
         cdl_number, cdl_state, cdl_expiry_date, medical_card_expiry_date, hire_date,
         date_of_birth, status, home_terminal_city, home_terminal_state,
         notes, created_at, updated_at,
         employee_number, photo_url, photo_shareable, gender, address_line1, city, state, postal_code,
         emergency_contact_name, emergency_contact_phone, department, cdl_class,
         cdl_restrictions, cdl_endorsements, medical_card_number, drug_test_date,
         drug_test_expiry_date, background_check_date, background_check_status,
         mvr_date, mvr_status, twic_expiry_date, hazmat_endorsement_expiry_date,
         passport_number, passport_expiry_date, work_authorization_status,
         work_authorization_expiry_date, direct_deposit_bank_name,
         direct_deposit_account_last4, ssn_last4, worker_type`
      )
      .eq("id", id)
      .single(),
    supabase.from("carriers").select("id, legal_name").order("legal_name"),
    supabase.auth.getUser(),
    supabase
      .from("driver_portal_credentials")
      .select("phone, is_active, last_login_at")
      .eq("driver_id", id)
      .maybeSingle(),
    // Real trip count for the Trip History section badge -- total
    // dispatches ever for this driver, not the (possibly range-filtered)
    // count DriverTripHistorySection itself renders inside.
    supabase.from("dispatches").select("id", { count: "exact", head: true }).eq("driver_id", id),
  ]);
  if (!driver) notFound();

  const { data: profile } = await supabase.from("profiles").select("role").eq("id", user.user!.id).single();
  const isOwnerOrAdmin = profile?.role === "owner" || profile?.role === "admin";
  const canManagePortalAccess = ["owner", "admin", "dispatcher"].includes(profile?.role ?? "");
  // Phase 2G.9 (item 3): Trip History (below) computes per-trip rate/
  // carrier_net_amount and revenue-per-mile metrics throughout -- it's a
  // revenue-reporting section, not incidentally financial, so it's gated
  // as a whole rather than field-by-field (same treatment as
  // Profitability/Settlement sections on Customer/Broker/Carrier Detail).
  const canSeeFinancials = FINANCIAL_ROLES.includes((profile?.role as OrgRole | null) ?? ("viewer" as OrgRole));
  // Phase 2Q.2B -- Driver W-9, only queried/shown when this driver's own
  // worker_type actually requires one (Section P).
  const requiresW9 = workerTypeRequiresW9(driver.worker_type as DriverWorkerType | null);
  const w9Query = requiresW9
    ? await supabase.from("driver_w9s").select(DRIVER_W9_STAFF_SAFE_SELECT).eq("driver_id", id).order("created_at", { ascending: false }).limit(1).maybeSingle()
    : { data: null };
  const driverW9 = (w9Query.data as unknown as DriverW9Row | null) ?? null;

  // driver_compensation query itself only runs for canSeeFinancials -- not
  // merely hidden in the Payroll section's JSX below.
  const { data: driverCompensation } = canSeeFinancials
    ? await supabase.from("driver_compensation").select("pay_type, pay_rate").eq("driver_id", id).maybeSingle()
    : { data: null };

  const tripCount = tripCountRes.count ?? 0;
  const complianceAlerts = expiringCount(driver);

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Drivers", href: "/drivers" }, { label: `${driver.first_name} ${driver.last_name}`, href: `/drivers/${id}` }]} />
      <RegisterDesktopActions
        title={`${driver.first_name} ${driver.last_name}`}
        printInPlace
        exportDisabledReason="No PDF export yet for Driver Profile -- use Print, then Save as PDF for a safe operational summary."
        emailDisabledReason="Email is not available for Driver Profile."
      />

      <CollapsibleSectionsProvider defaults={SECTION_DEFAULTS}>
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">{driver.first_name} {driver.last_name}</h1>
            <p className="mt-0.5 text-xs text-muted-foreground">Driver profile. Changes save immediately.</p>
          </div>
          <CollapsibleSectionsToolbar />
        </div>

        <div className="rounded-md border border-desktop-border bg-card shadow-elevation-1">
          <div className="flex h-7 items-center rounded-t-md bg-desktop-header px-3 text-[11px] font-semibold uppercase tracking-wide text-desktop-header-text">
            {driver.first_name} {driver.last_name}
          </div>
          <div className="space-y-2 p-3">
            {/* One <form> for the whole profile, exactly as before -- every
                collapsible section below just hides/shows a slice of the
                SAME form via CSS (see DesktopCollapsibleSection), so
                collapsing never drops a field from the submit and Save
                still saves everything in one action, collapsed or not. */}
            <form id="driver-form" action={updateDriver.bind(null, id)} className="space-y-2">
              <DesktopCollapsibleSection id="employment" title="Employment" description="Which carrier this driver works under.">
                <FormGrid>
                  <FormSelect
                    label="Carrier"
                    name="carrier_id"
                    required
                    defaultValue={driver.carrier_id}
                    options={(carriers ?? []).map((c) => ({ value: c.id, label: c.legal_name }))}
                  />
                  <FormSelect
                    label="Status"
                    name="status"
                    defaultValue={driver.status}
                    options={[
                      { value: "active", label: "Active" },
                      { value: "inactive", label: "Inactive" },
                      { value: "on_leave", label: "On Leave" },
                      { value: "applicant", label: "Applicant" },
                      { value: "terminated", label: "Terminated" },
                    ]}
                  />
                  <FormField label="Employee number" name="employee_number" defaultValue={driver.employee_number} />
                  <FormField label="Department" name="department" defaultValue={driver.department} />
                  <FormField label="Hire date" name="hire_date" type="date" defaultValue={driver.hire_date} />
                  <FormField label="Home terminal city" name="home_terminal_city" defaultValue={driver.home_terminal_city} />
                  <FormField label="Home terminal state" name="home_terminal_state" defaultValue={driver.home_terminal_state} />
                </FormGrid>
              </DesktopCollapsibleSection>

              <DesktopCollapsibleSection id="personal" title="Personal Information" description="Contact and identity details. SSN lives in Sensitive Information below.">
                <FormGrid>
                  <FormField label="First name" name="first_name" defaultValue={driver.first_name} required />
                  <FormField label="Middle name" name="middle_name" defaultValue={driver.middle_name} />
                  <FormField label="Last name" name="last_name" defaultValue={driver.last_name} required />
                  <FormField label="Phone" name="phone" type="tel" defaultValue={driver.phone} />
                  <FormField label="Email" name="email" type="email" defaultValue={driver.email} />
                  <FormField label="Date of birth" name="date_of_birth" type="date" defaultValue={driver.date_of_birth} />
                  <FormSelect
                    label="Gender"
                    name="gender"
                    defaultValue={driver.gender}
                    options={[
                      { value: "male", label: "Male" },
                      { value: "female", label: "Female" },
                      { value: "other", label: "Other" },
                      { value: "prefer_not_to_say", label: "Prefer not to say" },
                    ]}
                  />
                  <FormField label="Address" name="address_line1" defaultValue={driver.address_line1} />
                  <FormField label="City" name="city" defaultValue={driver.city} />
                  <FormField label="State" name="state" defaultValue={driver.state} />
                  <FormField label="Postal code" name="postal_code" defaultValue={driver.postal_code} />
                  <FormField label="Emergency contact name" name="emergency_contact_name" defaultValue={driver.emergency_contact_name} />
                  <FormField label="Emergency contact phone" name="emergency_contact_phone" type="tel" defaultValue={driver.emergency_contact_phone} />
                  <FormField label="Photo URL" name="photo_url" defaultValue={driver.photo_url} />
                  <label className="flex items-center gap-2 text-sm font-medium sm:col-span-2">
                    <input type="checkbox" name="photo_shareable" defaultChecked={driver.photo_shareable} className="size-4 rounded border-desktop-border" />
                    Approve this photo for external (broker/customer) profile sharing -- off by default
                  </label>
                </FormGrid>
              </DesktopCollapsibleSection>

              <DesktopCollapsibleSection id="cdl" title="CDL Information" description="Commercial driver's license.">
                <FormGrid>
                  <FormField label="CDL number" name="cdl_number" defaultValue={driver.cdl_number} />
                  <FormField label="CDL state" name="cdl_state" defaultValue={driver.cdl_state} />
                  <FormSelect
                    label="CDL class"
                    name="cdl_class"
                    defaultValue={driver.cdl_class}
                    options={[
                      { value: "A", label: "Class A" },
                      { value: "B", label: "Class B" },
                      { value: "C", label: "Class C" },
                    ]}
                  />
                  <FormField label="CDL restrictions" name="cdl_restrictions" defaultValue={driver.cdl_restrictions} />
                  <FormField label="CDL endorsements" name="cdl_endorsements" defaultValue={driver.cdl_endorsements} />
                  <FormField label="CDL expiry date" name="cdl_expiry_date" type="date" defaultValue={driver.cdl_expiry_date} />
                </FormGrid>
              </DesktopCollapsibleSection>

              <DesktopCollapsibleSection
                id="medical_compliance"
                title="Medical / Compliance"
                description="Medical card, drug testing, background check, and MVR."
                badge={complianceAlerts > 0 ? `⚠ ${complianceAlerts}` : undefined}
                badgeTone="warning"
              >
                <FormGrid>
                  <FormField label="Medical card number" name="medical_card_number" defaultValue={driver.medical_card_number} />
                  <FormField label="Medical card expiry date" name="medical_card_expiry_date" type="date" defaultValue={driver.medical_card_expiry_date} />
                  <FormField label="Drug test date" name="drug_test_date" type="date" defaultValue={driver.drug_test_date} />
                  <FormField label="Drug test expiry date" name="drug_test_expiry_date" type="date" defaultValue={driver.drug_test_expiry_date} />
                  <FormField label="Background check date" name="background_check_date" type="date" defaultValue={driver.background_check_date} />
                  <FormSelect
                    label="Background check status"
                    name="background_check_status"
                    defaultValue={driver.background_check_status}
                    options={[
                      { value: "pending", label: "Pending" },
                      { value: "passed", label: "Passed" },
                      { value: "failed", label: "Failed" },
                    ]}
                  />
                  <FormField label="MVR date" name="mvr_date" type="date" defaultValue={driver.mvr_date} />
                  <FormSelect
                    label="MVR status"
                    name="mvr_status"
                    defaultValue={driver.mvr_status}
                    options={[
                      { value: "pending", label: "Pending" },
                      { value: "passed", label: "Passed" },
                      { value: "failed", label: "Failed" },
                    ]}
                  />
                  <FormField label="TWIC expiry date" name="twic_expiry_date" type="date" defaultValue={driver.twic_expiry_date} />
                  <FormField label="Hazmat endorsement expiry date" name="hazmat_endorsement_expiry_date" type="date" defaultValue={driver.hazmat_endorsement_expiry_date} />
                </FormGrid>
              </DesktopCollapsibleSection>

              {requiresW9 && (
                <DesktopCollapsibleSection id="tax_w9" title="Tax (W-9)" description="Required for this driver's worker type. Full TIN is never shown here.">
                  <DriverW9Card w9={driverW9} />
                </DesktopCollapsibleSection>
              )}

              <DesktopCollapsibleSection id="work_auth" title="Identification & Work Authorization" description="Passport and eligibility to work in the US.">
                <FormGrid>
                  <FormField label="Passport number" name="passport_number" defaultValue={driver.passport_number} />
                  <FormField label="Passport expiry date" name="passport_expiry_date" type="date" defaultValue={driver.passport_expiry_date} />
                  <FormSelect
                    label="Work authorization status"
                    name="work_authorization_status"
                    defaultValue={driver.work_authorization_status}
                    options={[
                      { value: "citizen", label: "US Citizen" },
                      { value: "permanent_resident", label: "Permanent Resident" },
                      { value: "visa", label: "Visa" },
                      { value: "ead", label: "Employment Authorization Document" },
                      { value: "other", label: "Other" },
                    ]}
                  />
                  <FormField label="Work authorization expiry date" name="work_authorization_expiry_date" type="date" defaultValue={driver.work_authorization_expiry_date} />
                </FormGrid>
              </DesktopCollapsibleSection>

              {canSeeFinancials && (
                <DesktopCollapsibleSection id="payroll" title="Payroll" description="Pay structure. Never shown to drivers or carriers. Direct deposit numbers are in Sensitive Information." badge="STAFF ONLY" badgeTone="warning">
                  <FormGrid>
                    <FormSelect
                      label="Pay type"
                      name="pay_type"
                      defaultValue={driverCompensation?.pay_type ?? undefined}
                      options={[
                        { value: "per_mile", label: "Per mile" },
                        { value: "percentage", label: "Percentage" },
                        { value: "hourly", label: "Hourly" },
                        { value: "salary", label: "Salary" },
                      ]}
                    />
                    <FormField label="Pay rate" name="pay_rate" type="number" step="0.01" defaultValue={driverCompensation?.pay_rate ?? undefined} />
                    <FormField label="Direct deposit bank name" name="direct_deposit_bank_name" defaultValue={driver.direct_deposit_bank_name} />
                  </FormGrid>
                </DesktopCollapsibleSection>
              )}
              <DesktopCollapsibleSection id="notes" title="Notes">
                <FormGrid>
                  <FormTextarea label="Notes" name="notes" defaultValue={driver.notes} />
                </FormGrid>
              </DesktopCollapsibleSection>
            </form>

            <div className="flex items-center justify-between border-t border-desktop-border pt-3">
              <div>
                <ConfirmDeleteForm action={deleteRecord.bind(null, "drivers", id, "/drivers")} />
              </div>
              <div className="flex items-center gap-2">
                <Link
                  href="/drivers"
                  className="inline-flex h-8 items-center rounded-sm px-3 text-[13px] font-medium text-muted-foreground transition-colors hover:bg-muted"
                >
                  Cancel
                </Link>
                <Button type="submit" form="driver-form">
                  Save
                </Button>
              </div>
            </div>
          </div>
        </div>

        {canSeeFinancials && (
          <DesktopCollapsibleSection id="trip_history" title="Trip History" badge={tripCount || undefined}>
            <DriverTripHistorySection
              driverId={id}
              organizationId={driver.organization_id}
              range={(range as DateRangeKey) ?? "all"}
              customFrom={from}
              customTo={to}
            />
          </DesktopCollapsibleSection>
        )}

        {canManagePortalAccess && (
          <DesktopCollapsibleSection id="portal_access" title="Driver Portal Access" description="Sign-in on their phone at /driver-portal for their active dispatch and live location.">
            <div className="flex items-center gap-2 pb-2">
              <Radio className="size-4 text-primary" />
              <p className="text-xs text-muted-foreground">Portal credential for this driver.</p>
            </div>
            <PortalAccessForm
              driverId={id}
              isActive={portalCredential?.is_active ?? false}
              currentPhone={portalCredential?.phone ?? driver.phone ?? null}
              lastLoginAt={portalCredential?.last_login_at ?? null}
              onSetPin={setDriverPortalPin}
              onRevoke={revokeDriverPortalAccess}
            />
          </DesktopCollapsibleSection>
        )}

        <DesktopCollapsibleSection id="settlement_summary" title="Settlement Summary">
          <DriverSettlementSummarySection driverId={id} />
        </DesktopCollapsibleSection>

        <DesktopCollapsibleSection id="driver_pay" title="Driver Pay">
          <DriverPaySection driverId={id} />
        </DesktopCollapsibleSection>

        <DesktopCollapsibleSection id="profitability" title="Profitability">
          <DriverProfitabilitySection driverId={id} />
        </DesktopCollapsibleSection>

        <DesktopCollapsibleSection id="company_expenses" title="Company-Paid Expenses">
          <DriverExpenseSummarySection driverId={id} />
        </DesktopCollapsibleSection>

        <DesktopCollapsibleSection id="share_profile" title="Share External Profile" className="print:hidden">
          <ShareExternalProfileSection entity={{ type: "driver", driverId: id }} />
        </DesktopCollapsibleSection>

        {isOwnerOrAdmin && (
          <DesktopCollapsibleSection
            id="sensitive"
            title="Sensitive Information"
            description="Encrypted at rest. Only owners and admins can reveal these values; every reveal is logged."
            className="print:hidden"
          >
            <div className="flex justify-end pb-2">
              <Link href={`/drivers/${id}/access-log`} className="flex items-center gap-1 text-xs font-medium text-primary hover:underline">
                <ShieldCheck className="size-3.5" />
                View access log &rarr;
              </Link>
            </div>
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <div>
                <p className="mb-1.5 text-xs font-medium text-muted-foreground">Social Security Number</p>
                {driver.ssn_last4 ? (
                  <RevealPiiButton
                    maskedValue={`***-**-${driver.ssn_last4}`}
                    onReveal={revealDriverPii.bind(null, id, "ssn")}
                    promptForReason
                  />
                ) : (
                  <SetPiiForm label="Set SSN" placeholder="000-00-0000" onSave={setDriverPii.bind(null, id, "ssn")} />
                )}
              </div>
              <div>
                <p className="mb-1.5 text-xs font-medium text-muted-foreground">Direct Deposit Account #</p>
                {driver.direct_deposit_account_last4 ? (
                  <RevealPiiButton
                    maskedValue={`••••••${driver.direct_deposit_account_last4}`}
                    onReveal={revealDriverPii.bind(null, id, "direct_deposit_account")}
                    promptForReason
                  />
                ) : (
                  <SetPiiForm
                    label="Set account number"
                    placeholder="000123456789"
                    onSave={setDriverPii.bind(null, id, "direct_deposit_account")}
                  />
                )}
              </div>
            </div>
          </DesktopCollapsibleSection>
        )}
      </CollapsibleSectionsProvider>
    </div>
  );
}
