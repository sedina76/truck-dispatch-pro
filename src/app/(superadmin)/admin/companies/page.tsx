import Link from "next/link";
import { getPlatformOverview } from "@/lib/superadmin/platform-metrics";
import { ACCESS_STYLE, type CompanyAccess } from "@/lib/superadmin/company-access";
import { PageHeader } from "@/components/ui/page-header";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";

type CompanyRow = {
  id: string;
  name: string;
  slug: string;
  created_at: string;
  planName: string;
  access: CompanyAccess;
};

export default async function SuperAdminCompaniesPage() {
  // Same rows as the Overview table (one canonical source), including the
  // company's real access state rather than only its subscription status.
  const { companies } = await getPlatformOverview();
  const rows: CompanyRow[] = companies.map((c) => ({
    id: c.id,
    name: c.name,
    slug: c.slug,
    created_at: c.createdAt,
    planName: c.planName ?? "No plan",
    access: c.access,
  }));

  const columns: Column<CompanyRow>[] = [
    { header: "Company", cell: (r) => <span className="font-medium">{r.name}</span>, sortKey: "name" },
    { header: "Slug", cell: (r) => <span className="text-muted-foreground">{r.slug}</span> },
    { header: "Plan", cell: (r) => r.planName },
    {
      header: "Access",
      cell: (r) => (
        <span title={r.access.detail} className={`inline-flex items-center whitespace-nowrap rounded-full px-2 py-0.5 text-[11px] font-medium ${ACCESS_STYLE[r.access.key]}`}>
          {r.access.label}
        </span>
      ),
    },
    {
      header: "Joined",
      cell: (r) => new Date(r.created_at).toLocaleDateString(),
      sortKey: "created_at",
    },
    {
      // DataTable already renders View/Edit icon actions (pointing at
      // getDetailHref below) for every row -- this column adds the two
      // MORE specific jump-to-tab links the spec also asks for (spec
      // section 24: "Manage Admins", "Manage Subscription"), without
      // duplicating the auto-generated View/Edit.
      header: "Manage",
      cell: (r) => (
        <div className="flex items-center gap-2.5 text-xs font-medium">
          <Link href={`/admin/companies/${r.id}?tab=admins`} className="text-primary hover:underline">
            Admins
          </Link>
          <Link href={`/admin/companies/${r.id}?tab=subscription`} className="text-primary hover:underline">
            Subscription
          </Link>
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Companies"
        description="Every tenant organization on the platform."
        primaryAction={{ label: "Add Company", href: "/admin/companies/new" }}
      />

      {rows.length === 0 ? (
        <EmptyState title="No companies yet" description="New signups will show up here." />
      ) : (
        <DataTable columns={columns} rows={rows} getDetailHref={(r) => `/admin/companies/${r.id}`} pageSize={20} />
      )}
    </div>
  );
}
