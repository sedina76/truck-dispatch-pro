import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { KpiRow, KpiCard } from "@/components/ui/kpi-card";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { ComplianceNav } from "@/components/compliance/compliance-nav";

type ComplianceItem = {
  id: string;
  entity_type: string;
  item_type: string;
  expiry_date: string | null;
  status: string;
};

export default async function CompliancePage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q } = await searchParams;
  const supabase = await createClient();

  let query = supabase
    .from("compliance_items")
    .select("id, entity_type, item_type, expiry_date, status")
    .order("expiry_date", { ascending: true, nullsFirst: false });
  if (q) query = query.ilike("item_type", `%${q}%`);

  const { data } = await query;
  const items = (data ?? []) as ComplianceItem[];

  const { count: totalCount } = await supabase
    .from("compliance_items")
    .select("id", { count: "exact", head: true });
  const { count: validCount } = await supabase
    .from("compliance_items")
    .select("id", { count: "exact", head: true })
    .eq("status", "valid");
  const { count: expiringSoonCount } = await supabase
    .from("compliance_items")
    .select("id", { count: "exact", head: true })
    .eq("status", "expiring_soon");
  const { count: expiredCount } = await supabase
    .from("compliance_items")
    .select("id", { count: "exact", head: true })
    .eq("status", "expired");

  const columns: Column<ComplianceItem>[] = [
    { header: "Entity", cell: (row) => <span className="capitalize">{row.entity_type}</span> },
    { header: "Requirement", cell: (row) => <span className="capitalize">{row.item_type.replace(/_/g, " ")}</span> },
    { header: "Expiry Date", cell: (row) => row.expiry_date ?? "--" },
    { header: "Status", cell: (row) => <StatusBadge status={row.status} /> },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Compliance Center"
        description="Expiring and expired credentials across drivers, trucks, and carriers."
        primaryAction={{ label: "Add Compliance Item", href: "/compliance/new" }}
      />

      <div className="flex flex-wrap items-center justify-between gap-3">
        <ComplianceNav />
        <Link href="/documents" className="text-sm font-medium text-primary hover:underline">
          Document Library &rarr;
        </Link>
      </div>

      <KpiRow>
        <KpiCard label="Total Tracked" value={totalCount ?? 0} />
        <KpiCard label="Valid" value={validCount ?? 0} />
        <KpiCard label="Expiring Soon" value={expiringSoonCount ?? 0} tone={expiringSoonCount ? "warning" : "neutral"} />
        <KpiCard label="Expired" value={expiredCount ?? 0} tone={expiredCount ? "danger" : "neutral"} />
      </KpiRow>

      <SearchBar placeholder="Search by requirement type..." />

      {items.length === 0 ? (
        <EmptyState
          title={q ? "No compliance items match your search" : "No compliance items tracked yet"}
          description={
            q ? "Try a different search term." : "Track CDL, insurance, medical card, and inspection expirations."
          }
          action={{ label: "Add Compliance Item", href: "/compliance/new" }}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={items}
          getDetailHref={(row) => `/compliance/${row.id}`}
          getDeleteAction={(row) => deleteRecord.bind(null, "compliance_items", row.id, "/compliance")}
        />
      )}
    </div>
  );
}
