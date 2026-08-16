import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";

type Doc = {
  id: string;
  file_name: string;
  entity_type: string;
  document_type: string;
  expiry_date: string | null;
  is_verified: boolean;
};

export default async function DocumentsPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q } = await searchParams;
  const supabase = await createClient();

  let query = supabase
    .from("documents")
    .select("id, file_name, entity_type, document_type, expiry_date, is_verified")
    .order("created_at", { ascending: false });
  if (q) query = query.ilike("file_name", `%${q}%`);

  const { data } = await query;
  const documents = (data ?? []) as Doc[];

  const { count: totalCount } = await supabase.from("documents").select("id", { count: "exact", head: true });
  const { count: unverifiedCount } = await supabase
    .from("documents")
    .select("id", { count: "exact", head: true })
    .eq("is_verified", false);

  const expiringSoon = documents.filter((d) => {
    if (!d.expiry_date) return false;
    const days = (new Date(d.expiry_date).getTime() - Date.now()) / 86_400_000;
    return days >= 0 && days <= 30;
  }).length;

  const columns: Column<Doc>[] = [
    { header: "File", cell: (row) => <span className="font-medium">{row.file_name}</span> },
    { header: "Entity", cell: (row) => <span className="capitalize">{row.entity_type}</span> },
    { header: "Document Type", cell: (row) => <span className="capitalize">{row.document_type.replace(/_/g, " ")}</span> },
    { header: "Expiry", cell: (row) => row.expiry_date ?? "--" },
    {
      header: "Verified",
      cell: (row) => <StatusBadge status={row.is_verified ? "valid" : "missing"} />,
    },
  ];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Documents", href: "/documents" }]} />
      <PageHeader
        title="Documents"
        description="Global document library across loads, carriers, and drivers."
        primaryAction={{ label: "Add Document", href: "/documents/new" }}
      />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total Documents" value={totalCount ?? 0} />
        <DesktopKpiBox label="Expiring Soon (30d)" value={expiringSoon} tone={expiringSoon ? "warning" : "neutral"} />
        <DesktopKpiBox label="Unverified" value={unverifiedCount ?? 0} tone={unverifiedCount ? "warning" : "neutral"} />
      </DesktopKpiStrip>

      <SearchBar placeholder="Search documents by file name..." />

      {documents.length === 0 ? (
        <EmptyState
          title={q ? "No documents match your search" : "No documents yet"}
          description={q ? "Try a different search term." : "Upload rate confirmations, PODs, CDLs, and more."}
          action={{ label: "Add Document", href: "/documents/new" }}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={documents}
          getDetailHref={(row) => `/documents/${row.id}`}
          getDeleteAction={(row) => deleteRecord.bind(null, "documents", row.id, "/documents")}
        />
      )}
    </div>
  );
}
