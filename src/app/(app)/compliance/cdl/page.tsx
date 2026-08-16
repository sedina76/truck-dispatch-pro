import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { KpiRow, KpiCard } from "@/components/ui/kpi-card";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { ComplianceNav } from "@/components/compliance/compliance-nav";

type DriverCdl = {
  id: string;
  first_name: string;
  last_name: string;
  cdl_number: string | null;
  cdl_state: string | null;
  cdl_class: string | null;
  cdl_endorsements: string | null;
  cdl_restrictions: string | null;
  cdl_expiry_date: string | null;
  medical_card_expiry_date: string | null;
  carriers: { legal_name: string } | null;
};

function expiryStatus(expiry: string | null): string {
  if (!expiry) return "missing";
  const days = (new Date(expiry).getTime() - Date.now()) / 86_400_000;
  if (days < 0) return "expired";
  if (days <= 30) return "expiring_soon";
  return "valid";
}

export default async function CdlCompliancePage() {
  const supabase = await createClient();

  const { data } = await supabase
    .from("drivers")
    .select(
      "id, first_name, last_name, cdl_number, cdl_state, cdl_class, cdl_endorsements, cdl_restrictions, cdl_expiry_date, medical_card_expiry_date, carriers(legal_name)"
    )
    .eq("status", "active")
    .order("cdl_expiry_date", { ascending: true, nullsFirst: false });

  const drivers = (data ?? []) as unknown as DriverCdl[];
  const cdlExpiring = drivers.filter((d) => expiryStatus(d.cdl_expiry_date) === "expiring_soon").length;
  const cdlExpired = drivers.filter((d) => expiryStatus(d.cdl_expiry_date) === "expired").length;
  const medExpiring = drivers.filter((d) => expiryStatus(d.medical_card_expiry_date) === "expiring_soon").length;

  const columns: Column<DriverCdl>[] = [
    { header: "Driver", cell: (row) => <span className="font-medium">{row.first_name} {row.last_name}</span> },
    { header: "Carrier", cell: (row) => row.carriers?.legal_name ?? "--" },
    { header: "CDL #", cell: (row) => `${row.cdl_number ?? "--"} (${row.cdl_state ?? "--"})` },
    { header: "Class", cell: (row) => row.cdl_class ?? "--" },
    { header: "Endorsements", cell: (row) => row.cdl_endorsements ?? "--" },
    {
      header: "CDL Expiry",
      cell: (row) => (
        <div className="flex items-center gap-2">
          <span>{row.cdl_expiry_date ?? "--"}</span>
          <StatusBadge status={expiryStatus(row.cdl_expiry_date)} />
        </div>
      ),
    },
    {
      header: "Medical Card",
      cell: (row) => (
        <div className="flex items-center gap-2">
          <span>{row.medical_card_expiry_date ?? "--"}</span>
          <StatusBadge status={expiryStatus(row.medical_card_expiry_date)} />
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader title="CDL & Medical Certification" description="License and DOT medical card status for every active driver." />

      <ComplianceNav />

      <KpiRow>
        <KpiCard label="Active Drivers" value={drivers.length} />
        <KpiCard label="CDL Expiring Soon" value={cdlExpiring} tone={cdlExpiring ? "warning" : "neutral"} />
        <KpiCard label="CDL Expired" value={cdlExpired} tone={cdlExpired ? "danger" : "neutral"} />
        <KpiCard label="Medical Card Expiring" value={medExpiring} tone={medExpiring ? "warning" : "neutral"} />
      </KpiRow>

      {drivers.length === 0 ? (
        <EmptyState title="No active drivers yet" description="Add drivers to start tracking their CDL and medical certification." />
      ) : (
        <DataTable columns={columns} rows={drivers} getDetailHref={(row) => `/drivers/${row.id}`} />
      )}
    </div>
  );
}
