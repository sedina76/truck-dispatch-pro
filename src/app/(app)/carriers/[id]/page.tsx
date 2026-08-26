import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid } from "@/components/ui/form-field";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { updateCarrier } from "../actions";
import { CarrierSettlementSummarySection } from "@/components/carriers/carrier-settlement-summary-section";
import { CarrierCompanyProfitabilitySection } from "@/components/carriers/carrier-company-profitability-section";
import { CarrierExpenseSummarySection } from "@/components/carriers/carrier-expense-summary-section";
import { ShareExternalProfileSection } from "@/components/loads/share-external-profile-section";
import { ComplianceTab } from "@/components/carrier-compliance/compliance-tab";
import type { CarrierComplianceReadiness } from "@/lib/carrier-compliance/types";
import { W9_STAFF_SAFE_SELECT, type CarrierW9Row } from "@/lib/carrier-w9/types";
import { FINANCIAL_ROLES, type OrgRole } from "@/lib/auth/require-role";

// Phase 2G.9 (item 3): same treatment as Customer/Broker Detail -- Carriers
// is Business, open to every role, no layout guard.
export default async function CarrierDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: roleData } = await supabase.rpc("current_role");
  const canSeeFinancials = FINANCIAL_ROLES.includes((roleData as OrgRole | null) ?? ("viewer" as OrgRole));

  const { data: carrier } = await supabase.from("carriers").select("*").eq("id", id).single();
  if (!carrier) notFound();

  const [{ data: drivers }, { data: trucks }, { data: trailers }, { data: pendingAdvances }, { data: carrierFinancials }, { data: onboardingApplication }] = await Promise.all([
    supabase.from("drivers").select("id, first_name, last_name, status").eq("carrier_id", id),
    supabase.from("trucks").select("id, unit_number, status").eq("carrier_id", id),
    supabase.from("trailers").select("id, unit_number, status").eq("carrier_id", id),
    canSeeFinancials
      ? supabase
          .from("dispatch_advances")
          .select("id, expense_type, description, amount, paid_date")
          .eq("carrier_id", id)
          .eq("status", "pending")
          .order("paid_date", { ascending: false })
      : Promise.resolve({ data: [] as never[] }),
    // Phase 2G.12: dispatch_fee_percentage/payment_terms_days moved to
    // carrier_financials (writer already cut over in 2G.10) -- carriers'
    // own copies are stale the moment either is edited. Fetched only for
    // canSeeFinancials, not merely hidden in JSX below.
    canSeeFinancials
      ? supabase.from("carrier_financials").select("dispatch_fee_percentage, payment_terms_days, factoring_company_name").eq("carrier_id", id).maybeSingle()
      : Promise.resolve({ data: null }),
    supabase.from("carrier_onboarding_applications").select("id, status").eq("converted_carrier_id", id).order("converted_at", { ascending: false }).limit(1).maybeSingle(),
  ]);

  const pendingAdvanceTotal = (pendingAdvances ?? []).reduce((sum, a) => sum + Number(a.amount), 0);

  // Phase 2P.3 -- Compliance tab. carrier_dispatch_readiness() is called
  // exactly once per page render and is the sole source of readiness truth;
  // nothing here recomputes W-9/agreement/insurance/identifier status.
  const { data: readinessData, error: readinessErrorObj } = await supabase.rpc("carrier_dispatch_readiness", { p_carrier_id: id });
  const readiness = (readinessData ?? null) as CarrierComplianceReadiness | null;

  const [{ data: activeSuspension }, { data: w9Row, error: w9Error }] = await Promise.all([
    readiness?.status === "SUSPENDED"
      ? supabase.from("carrier_suspensions").select("reason, suspended_at, suspended_by").eq("carrier_id", id).is("lifted_at", null).limit(1).maybeSingle()
      : Promise.resolve({ data: null }),
    // Reused evidence-view path only, never a separate readiness computation.
    // Phase 2P.3A: carrier_w9s's authenticated SELECT grant deliberately
    // excludes tin_encrypted, so select("*") fails outright for every
    // authenticated caller -- must use the exact safe column list.
    onboardingApplication
      ? supabase.from("carrier_w9s").select(W9_STAFF_SAFE_SELECT).eq("carrier_id", id).order("created_at", { ascending: false }).limit(1).maybeSingle()
      : Promise.resolve({ data: null, error: null }),
  ]);

  let suspendedByName: string | null = null;
  if (activeSuspension?.suspended_by) {
    const { data: suspendedByProfile } = await supabase.from("profiles").select("full_name").eq("id", activeSuspension.suspended_by).maybeSingle();
    suspendedByName = suspendedByProfile?.full_name ?? null;
  }

  return (
    <Tabs defaultValue="overview" className="space-y-4">
      <TabsList>
        <TabsTrigger value="overview">Overview</TabsTrigger>
        <TabsTrigger value="compliance">Compliance</TabsTrigger>
      </TabsList>

      <TabsContent value="overview" className="space-y-6">
      <FormCard
        title={carrier.legal_name}
        description="Carrier profile. Changes save immediately."
        action={updateCarrier.bind(null, id)}
        cancelHref="/carriers"
        deleteAction={deleteRecord.bind(null, "carriers", id, "/carriers")}
      >
        <FormGrid>
          <FormField label="Legal name" name="legal_name" defaultValue={carrier.legal_name} required />
          <FormField label="DBA name" name="dba_name" defaultValue={carrier.dba_name} />
          <FormField label="MC number" name="mc_number" defaultValue={carrier.mc_number} />
          <FormField label="DOT number" name="dot_number" defaultValue={carrier.dot_number} />
          <FormField label="Contact name" name="contact_name" defaultValue={carrier.contact_name} />
          <FormField label="Phone" name="phone" type="tel" defaultValue={carrier.phone} />
          <FormField label="Email" name="email" type="email" defaultValue={carrier.email} />
          <FormField label="City" name="city" defaultValue={carrier.city} />
          <FormField label="State" name="state" defaultValue={carrier.state} />
          {canSeeFinancials && (
            <>
              <FormField
                label="Dispatch fee %"
                name="dispatch_fee_percentage"
                type="number"
                step="0.01"
                defaultValue={carrierFinancials?.dispatch_fee_percentage}
                required
              />
              <FormField
                label="Payment terms (days)"
                name="payment_terms_days"
                type="number"
                defaultValue={carrierFinancials?.payment_terms_days}
              />
            </>
          )}
        </FormGrid>
      </FormCard>

      {canSeeFinancials && <CarrierSettlementSummarySection carrierId={id} />}

      {canSeeFinancials && <CarrierCompanyProfitabilitySection carrierId={id} />}

      {canSeeFinancials && <CarrierExpenseSummarySection carrierId={id} />}

      <ShareExternalProfileSection entity={{ type: "carrier", carrierId: id }} />

      {canSeeFinancials && onboardingApplication && (
        <div className="rounded-md border border-desktop-border bg-card p-4">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div><p className="text-[14px] font-semibold">Setup Packages</p><p className="text-[12.5px] text-muted-foreground">Generate and review immutable broker-ready carrier setup packages.</p></div>
            <Link href={`/carriers/onboarding/${onboardingApplication.id}`} className="text-[13px] font-medium text-primary hover:underline">Open package history</Link>
          </div>
        </div>
      )}

      <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
        <RelatedList title="Drivers" emptyLabel="No drivers yet" items={(drivers ?? []).map((d) => ({ id: d.id, label: `${d.first_name} ${d.last_name}`, status: d.status }))} href="/drivers" />
        <RelatedList title="Trucks" emptyLabel="No trucks yet" items={(trucks ?? []).map((t) => ({ id: t.id, label: t.unit_number, status: t.status }))} href="/trucks" />
        <RelatedList title="Trailers" emptyLabel="No trailers yet" items={(trailers ?? []).map((t) => ({ id: t.id, label: t.unit_number, status: t.status }))} href="/trailers" />
      </div>

      {canSeeFinancials && (
        <div className="rounded-xl border border-border bg-card p-4 shadow-elevation-1">
          <div className="flex items-center justify-between">
            <p className="text-sm font-medium">
              Pending Advances{pendingAdvanceTotal > 0 && <span className="ml-2 text-warning">${pendingAdvanceTotal.toLocaleString()}</span>}
            </p>
            <Link href={`/advances/new?carrier_id=${id}`} className="text-xs font-medium text-primary hover:underline">
              Add Advance &rarr;
            </Link>
          </div>
          {!pendingAdvances || pendingAdvances.length === 0 ? (
            <p className="mt-2 text-sm text-muted-foreground">No pending advances for this carrier.</p>
          ) : (
            <ul className="mt-2 divide-y divide-border">
              {pendingAdvances.map((a) => (
                <li key={a.id} className="flex items-center justify-between py-2 text-sm">
                  <Link href={`/advances/${a.id}`} className="min-w-0 truncate capitalize hover:underline">
                    {a.expense_type.replace(/_/g, " ")}
                    {a.description ? ` -- ${a.description}` : ""}
                  </Link>
                  <span className="shrink-0 font-medium">${Number(a.amount).toLocaleString()}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
      </TabsContent>

      <TabsContent value="compliance">
        <ComplianceTab
          carrierId={id}
          role={(roleData as OrgRole | null) ?? "viewer"}
          readiness={readiness}
          readinessError={readinessErrorObj?.message ?? null}
          suspension={activeSuspension ? { reason: activeSuspension.reason, suspended_at: activeSuspension.suspended_at, suspended_by_name: suspendedByName } : null}
          w9Embed={onboardingApplication ? { w9: (w9Row as unknown as CarrierW9Row) ?? null, w9LoadError: w9Error?.message ?? null, applicationId: onboardingApplication.id, organizationId: carrier.organization_id } : null}
        />
      </TabsContent>
    </Tabs>
  );
}

function RelatedList({
  title,
  items,
  emptyLabel,
  href,
}: {
  title: string;
  items: { id: string; label: string; status: string }[];
  emptyLabel: string;
  href: string;
}) {
  return (
    <div className="rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] p-4">
      <p className="text-sm font-medium">{title}</p>
      {items.length === 0 ? (
        <p className="mt-2 text-sm text-[var(--color-text-muted)]">{emptyLabel}</p>
      ) : (
        <ul className="mt-2 space-y-1">
          {items.map((item) => (
            <li key={item.id} className="flex items-center justify-between text-sm">
              <span>{item.label}</span>
              <span className="text-xs text-[var(--color-text-muted)]">{item.status}</span>
            </li>
          ))}
        </ul>
      )}
      <Link href={href} className="mt-3 inline-block text-xs font-medium text-[var(--color-brand)]">
        View all &rarr;
      </Link>
    </div>
  );
}
