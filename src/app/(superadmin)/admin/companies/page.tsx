import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { DataTable, type Column } from "@/components/ui/data-table";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmptyState } from "@/components/ui/empty-state";

type CompanyRow = {
  id: string;
  name: string;
  slug: string;
  created_at: string;
  planName: string;
  status: string | null;
};

export default async function SuperAdminCompaniesPage() {
  const supabase = await createClient();

  const [{ data: orgs }, { data: subs }] = await Promise.all([
    supabase.from("organizations").select("id, name, slug, created_at").order("created_at", { ascending: false }),
    supabase
      .from("organization_subscriptions")
      .select("organization_id, status, subscription_plans(name)"),
  ]);

  type SubRow = { organization_id: string; status: string; subscription_plans: { name: string } | null };
  const subByOrgId = new Map(
    ((subs ?? []) as unknown as SubRow[]).map((s) => [s.organization_id, s])
  );

  const rows: CompanyRow[] = (orgs ?? []).map((org) => {
    const sub = subByOrgId.get(org.id);
    return {
      id: org.id,
      name: org.name,
      slug: org.slug,
      created_at: org.created_at,
      planName: sub?.subscription_plans?.name ?? "No plan",
      status: sub?.status ?? null,
    };
  });

  const columns: Column<CompanyRow>[] = [
    { header: "Company", cell: (r) => <span className="font-medium">{r.name}</span>, sortKey: "name" },
    { header: "Slug", cell: (r) => <span className="text-muted-foreground">{r.slug}</span> },
    { header: "Plan", cell: (r) => r.planName },
    { header: "Status", cell: (r) => <StatusBadge status={r.status} /> },
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
