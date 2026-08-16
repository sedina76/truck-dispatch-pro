import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { KpiRow, KpiCard } from "@/components/ui/kpi-card";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { ComplianceNav } from "@/components/compliance/compliance-nav";

type Policy = {
  id: string;
  policy_type: string;
  insurer_name: string;
  policy_number: string | null;
  coverage_amount: number | null;
  expiry_date: string | null;
  carriers: { legal_name: string } | null;
};

function expiryStatus(expiry: string | null): string {
  if (!expiry) return "missing";
  const days = (new Date(expiry).getTime() - Date.now()) / 86_400_000;
  if (days < 0) return "expired";
  if (days <= 30) return "expiring_soon";
  return "valid";
}

export default async function InsurancePage() {
  const supabase = await createClient();

  const { data } = await supabase
    .from("insurance_policies")
    .select("id, policy_type, insurer_name, policy_number, coverage_amount, expiry_date, carriers(legal_name)")
    .order("expiry_date", { ascending: true, nullsFirst: false });

  const policies = (data ?? []) as unknown as Policy[];
  const expiringSoon = policies.filter((p) => expiryStatus(p.expiry_date) === "expiring_soon").length;
  const expired = policies.filter((p) => expiryStatus(p.expiry_date) === "expired").length;
  const companyPolicies = policies.filter((p) => !p.carriers).length;

  const columns: Column<Policy>[] = [
    { header: "Type", cell: (row) => <span className="capitalize">{row.policy_type.replace(/_/g, " ")}</span> },
    { header: "Covers", cell: (row) => row.carriers?.legal_name ?? "Company (own policy)" },
    { header: "Insurer", cell: (row) => row.insurer_name },
    { header: "Policy #", cell: (row) => row.policy_number ?? "--" },
    { header: "Coverage", cell: (row) => (row.coverage_amount ? `$${Number(row.coverage_amount).toLocaleString()}` : "--") },
    { header: "Expiry", cell: (row) => row.expiry_date ?? "--" },
    { header: "Status", cell: (row) => <StatusBadge status={expiryStatus(row.expiry_date)} /> },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Insurance"
        description="General liability, cargo, physical damage, and workers comp -- your company's and your carriers'."
        primaryAction={{ label: "Add Policy", href: "/compliance/insurance/new" }}
      />

      <ComplianceNav />

      <KpiRow>
        <KpiCard label="Total Policies" value={policies.length} />
        <KpiCard label="Company Policies" value={companyPolicies} />
        <KpiCard label="Expiring Soon" value={expiringSoon} tone={expiringSoon ? "warning" : "neutral"} />
        <KpiCard label="Expired" value={expired} tone={expired ? "danger" : "neutral"} />
      </KpiRow>

      {policies.length === 0 ? (
        <EmptyState
          title="No insurance policies on file"
          description="Add your company's own policies and each carrier's certificate of insurance."
          action={{ label: "Add Policy", href: "/compliance/insurance/new" }}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={policies}
          getDetailHref={(row) => `/compliance/insurance/${row.id}`}
          getDeleteAction={(row) => deleteRecord.bind(null, "insurance_policies", row.id, "/compliance/insurance")}
        />
      )}
    </div>
  );
}
