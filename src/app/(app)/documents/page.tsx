import Link from "next/link";
import { Lock } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { DocumentsFilterBar } from "@/components/documents/documents-filter-bar";
import {
  resolveDocumentOwners,
  entityTypesForCategoryKey,
  type BelongsTo,
} from "@/lib/documents/belongs-to";
import {
  computeDocumentStatus,
  matchesExpiryFilter,
  DOCUMENT_TYPE_OPTIONS,
  DELETE_PROTECTED_DOCUMENT_TYPES,
  type DocumentDisplayStatus,
} from "@/lib/documents/library";

// Global document library. Every row is a real uploaded file; this page is
// the cross-entity view (a carrier/load/driver record still shows its own
// documents on its own page). "Belongs To" is resolved to a business name
// via one centralized resolver (src/lib/documents/belongs-to.ts) in a
// bounded number of batched queries -- the table never prints a raw
// entity_type enum value, and never issues a per-row lookup.

type RawDoc = {
  id: string;
  file_name: string;
  entity_type: string;
  entity_id: string | null;
  document_type: string;
  expiry_date: string | null;
  is_verified: boolean;
};

type Row = {
  id: string;
  file_name: string;
  document_type: string;
  documentTypeLabel: string;
  belongsToName: string;
  belongsToSecondary: string | null;
  belongsToHref: string | null;
  belongsToUnresolved: boolean;
  category: string;
  status: DocumentDisplayStatus;
  expiry_date: string | null;
  isProtected: boolean;
};

// Hard cap: this is a load-all + client-paginate page (unchanged from
// before). The cap just bounds the owner-resolution work and the search
// scan -- a real deployment past this size wants a denormalized search
// column / server pagination, noted in the repair report.
const MAX_ROWS = 500;

// Status text is rendered through <StatusBadge/>, which title-cases the
// key itself ("expiring_soon" -> "Expiring Soon", etc.).
const DOC_TYPE_LABEL = new Map(DOCUMENT_TYPE_OPTIONS.map((o) => [o.value, o.label]));

function humanize(v: string): string {
  return v
    .split(/[_\s]+/)
    .filter(Boolean)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");
}

export default async function DocumentsPage({
  searchParams,
}: {
  searchParams: Promise<{
    q?: string;
    category?: string;
    type?: string;
    verification?: string;
    expiry?: string;
  }>;
}) {
  const { q, category, type, verification, expiry } = await searchParams;
  const supabase = await createClient();

  let query = supabase
    .from("documents")
    .select("id, file_name, entity_type, entity_id, document_type, expiry_date, is_verified")
    .order("created_at", { ascending: false })
    .limit(MAX_ROWS);

  const categoryEntityTypes = entityTypesForCategoryKey(category);
  if (categoryEntityTypes) query = query.in("entity_type", categoryEntityTypes);
  if (type && type !== "all") query = query.eq("document_type", type);
  if (verification === "verified") query = query.eq("is_verified", true);
  if (verification === "unverified") query = query.eq("is_verified", false);

  const { data, error } = await query;
  if (error) console.error("[documents library] query failed:", error);
  const rawDocs = (data ?? []) as RawDoc[];

  // One batched owner lookup per distinct entity_type on this page.
  const owners = await resolveDocumentOwners(supabase, rawDocs);

  const now = new Date();
  const search = (q ?? "").trim().toLowerCase();

  const rows: Row[] = rawDocs
    .map((d): Row => {
      const owner: BelongsTo =
        owners.get(d.id) ?? {
          category: humanize(d.entity_type),
          displayName: "Unlinked record",
          secondaryIdentifier: null,
          href: null,
          unresolved: true,
        };
      return {
        id: d.id,
        file_name: d.file_name,
        document_type: d.document_type,
        documentTypeLabel: DOC_TYPE_LABEL.get(d.document_type) ?? humanize(d.document_type),
        belongsToName: owner.displayName,
        belongsToSecondary: owner.secondaryIdentifier,
        belongsToHref: owner.href,
        belongsToUnresolved: owner.unresolved,
        category: owner.category,
        status: computeDocumentStatus(d.expiry_date, d.is_verified, now),
        expiry_date: d.expiry_date,
        isProtected: DELETE_PROTECTED_DOCUMENT_TYPES.has(d.document_type),
      };
    })
    .filter((r) => matchesExpiryFilter(expiry, r.expiry_date, now))
    .filter((r) => {
      if (!search) return true;
      return (
        r.file_name.toLowerCase().includes(search) ||
        r.belongsToName.toLowerCase().includes(search) ||
        (r.belongsToSecondary ?? "").toLowerCase().includes(search) ||
        r.category.toLowerCase().includes(search) ||
        r.documentTypeLabel.toLowerCase().includes(search)
      );
    });

  // KPI counts are global (not narrowed by the active filters), same as
  // the prior page's intent.
  const today = now.toISOString().slice(0, 10);
  const in30 = new Date(now.getTime() + 30 * 86_400_000).toISOString().slice(0, 10);
  const [{ count: totalCount }, { count: unverifiedCount }, { count: expiringSoonCount }, { count: expiredCount }] =
    await Promise.all([
      supabase.from("documents").select("id", { count: "exact", head: true }),
      supabase.from("documents").select("id", { count: "exact", head: true }).eq("is_verified", false),
      supabase
        .from("documents")
        .select("id", { count: "exact", head: true })
        .not("expiry_date", "is", null)
        .gte("expiry_date", today)
        .lte("expiry_date", in30),
      supabase
        .from("documents")
        .select("id", { count: "exact", head: true })
        .not("expiry_date", "is", null)
        .lt("expiry_date", today),
    ]);

  const columns: Column<Row>[] = [
    {
      header: "File",
      sortKey: "file_name",
      cell: (row) => <span className="font-medium">{row.file_name}</span>,
    },
    {
      header: "Belongs To",
      sortKey: "belongsToName",
      cell: (row) => (
        <div className="leading-tight">
          {row.belongsToHref ? (
            <Link href={row.belongsToHref} className="font-medium text-primary hover:underline">
              {row.belongsToName}
            </Link>
          ) : (
            <span className={row.belongsToUnresolved ? "text-muted-foreground italic" : "font-medium"}>
              {row.belongsToName}
            </span>
          )}
          {row.belongsToSecondary && (
            <div className="text-[11px] text-muted-foreground">{row.belongsToSecondary}</div>
          )}
        </div>
      ),
    },
    { header: "Category", sortKey: "category", cell: (row) => row.category },
    {
      header: "Document Type",
      sortKey: "documentTypeLabel",
      cell: (row) => (
        <span className="inline-flex items-center gap-1">
          {row.documentTypeLabel}
          {row.isProtected && (
            <Lock className="size-3 text-muted-foreground" aria-label="Protected — cannot be deleted" />
          )}
        </span>
      ),
    },
    {
      header: "Status",
      sortKey: "status",
      cell: (row) => <StatusBadge status={row.status} />,
    },
    {
      header: "Expiry",
      sortKey: "expiry_date",
      cell: (row) =>
        row.expiry_date ? (
          <span className={row.status === "expired" ? "text-desktop-danger" : undefined}>
            {new Date(row.expiry_date + "T00:00:00").toLocaleDateString()}
          </span>
        ) : (
          <span className="text-muted-foreground">--</span>
        ),
    },
  ];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Documents", href: "/documents" }]} />
      <PageHeader
        title="Documents"
        description="Business-readable document library across carriers, applicants, loads, drivers, brokers, and customers."
        primaryAction={{ label: "Add Document", href: "/documents/new" }}
      />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total Documents" value={totalCount ?? 0} />
        <DesktopKpiBox
          label="Expiring Soon (30d)"
          value={expiringSoonCount ?? 0}
          tone={expiringSoonCount ? "warning" : "neutral"}
        />
        <DesktopKpiBox label="Expired" value={expiredCount ?? 0} tone={expiredCount ? "danger" : "neutral"} />
        <DesktopKpiBox
          label="Unverified"
          value={unverifiedCount ?? 0}
          tone={unverifiedCount ? "warning" : "neutral"}
        />
      </DesktopKpiStrip>

      <div className="flex flex-col gap-2">
        <SearchBar placeholder="Search file, owner, load #, carrier, driver..." />
        <DocumentsFilterBar />
      </div>

      {rows.length === 0 ? (
        <EmptyState
          title={q || category || type || verification || expiry ? "No documents match your filters" : "No documents yet"}
          description={
            q || category || type || verification || expiry
              ? "Try clearing a filter or a different search term."
              : "Upload rate confirmations, PODs, CDLs, W-9s, and more."
          }
          action={{ label: "Add Document", href: "/documents/new" }}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={rows}
          getDetailHref={(row) => `/documents/${row.id}`}
          getDeleteAction={(row) =>
            row.isProtected ? undefined : deleteRecord.bind(null, "documents", row.id, "/documents")
          }
        />
      )}

      {rawDocs.length >= MAX_ROWS && (
        <p className="text-[11px] text-muted-foreground">
          Showing the {MAX_ROWS} most recent documents. Narrow with filters or search to see older records.
        </p>
      )}
    </div>
  );
}
