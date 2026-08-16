import { ShieldCheck, AlertTriangle } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId, deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { KpiRow, KpiCard } from "@/components/ui/kpi-card";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { ComplianceNav } from "@/components/compliance/compliance-nav";

type Violation = {
  id: string;
  violation_date: string;
  violation_type: string;
  severity: string;
  is_resolved: boolean;
  carriers: { legal_name: string } | null;
  drivers: { first_name: string; last_name: string } | null;
};

export default async function DotCompliancePage() {
  const supabase = await createClient();
  const orgId = await getCurrentOrgId();

  const [{ data: org }, { data: violations }, { data: inspections }] = await Promise.all([
    supabase
      .from("organizations")
      .select("usdot_authority_status, broker_authority_status, dispatch_authority_status, safety_rating, safety_rating_date, dot_number")
      .eq("id", orgId)
      .single(),
    supabase
      .from("dot_violations")
      .select("id, violation_date, violation_type, severity, is_resolved, carriers(legal_name), drivers(first_name, last_name)")
      .order("violation_date", { ascending: false }),
    supabase
      .from("compliance_items")
      .select("id", { count: "exact", head: true })
      .eq("item_type", "dot_inspection"),
  ]);

  const violationRows = (violations ?? []) as unknown as Violation[];
  const unresolvedCount = violationRows.filter((v) => !v.is_resolved).length;
  const criticalCount = violationRows.filter((v) => v.severity === "critical" && !v.is_resolved).length;

  const columns: Column<Violation>[] = [
    { header: "Date", cell: (row) => new Date(row.violation_date).toLocaleDateString() },
    { header: "Type", cell: (row) => row.violation_type },
    { header: "Carrier", cell: (row) => row.carriers?.legal_name ?? "--" },
    { header: "Driver", cell: (row) => (row.drivers ? `${row.drivers.first_name} ${row.drivers.last_name}` : "--") },
    { header: "Severity", cell: (row) => <StatusBadge status={row.severity === "critical" || row.severity === "high" ? "expired" : "expiring_soon"} /> },
    { header: "Status", cell: (row) => <StatusBadge status={row.is_resolved ? "completed" : "open"} /> },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="DOT Compliance"
        description="Operating authority, safety rating, and violation history."
        primaryAction={{ label: "Log Violation", href: "/compliance/dot/violations/new" }}
      />

      <ComplianceNav />

      <div className="grid grid-cols-1 gap-5 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <ShieldCheck className="size-4 text-primary" />
              Authority & Safety
            </CardTitle>
            <CardDescription>DOT# {org?.dot_number ?? "not set"}</CardDescription>
          </CardHeader>
          <CardContent className="grid grid-cols-2 gap-4 sm:grid-cols-4">
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">USDOT Authority</p>
              <div className="mt-1.5">
                <StatusBadge status={org?.usdot_authority_status ?? "missing"} />
              </div>
            </div>
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Broker Authority</p>
              <div className="mt-1.5">
                <StatusBadge status={org?.broker_authority_status ?? "missing"} />
              </div>
            </div>
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Dispatch Authority</p>
              <div className="mt-1.5">
                <StatusBadge status={org?.dispatch_authority_status ?? "missing"} />
              </div>
            </div>
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Safety Rating</p>
              <p className="mt-1.5 text-sm font-medium">{org?.safety_rating ?? "Not rated"}</p>
            </div>
          </CardContent>
        </Card>

        <KpiCard label="DOT Inspections Logged" value={inspections?.length ?? 0} icon={ShieldCheck} tone="neutral" />
      </div>

      <KpiRow>
        <KpiCard label="Total Violations" value={violationRows.length} />
        <KpiCard label="Unresolved" value={unresolvedCount} tone={unresolvedCount ? "warning" : "success"} icon={AlertTriangle} />
        <KpiCard label="Critical (Open)" value={criticalCount} tone={criticalCount ? "danger" : "success"} />
      </KpiRow>

      {violationRows.length === 0 ? (
        <EmptyState title="No violations on record" description="Your safety record is clean. Log a violation if one occurs." />
      ) : (
        <DataTable
          columns={columns}
          rows={violationRows}
          getDeleteAction={(row) => deleteRecord.bind(null, "dot_violations", row.id, "/compliance/dot")}
        />
      )}
    </div>
  );
}
