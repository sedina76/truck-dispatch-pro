import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";

type Customer = {
  id: string;
  company_name: string;
  contact_name: string | null;
  phone: string | null;
  email: string | null;
  payment_terms_days: number | null;
  is_active: boolean;
};

export default async function CustomersPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q } = await searchParams;
  const supabase = await createClient();

  let query = supabase
    .from("customers")
    .select("id, company_name, contact_name, phone, email, payment_terms_days, is_active")
    .order("company_name");
  if (q) query = query.ilike("company_name", `%${q}%`);

  const { data } = await query;
  const customers = (data ?? []) as Customer[];

  const { count: totalCount } = await supabase
    .from("customers")
    .select("id", { count: "exact", head: true });
  const { count: activeCount } = await supabase
    .from("customers")
    .select("id", { count: "exact", head: true })
    .eq("is_active", true);

  const columns: Column<Customer>[] = [
    { header: "Company", cell: (row) => <span className="font-medium">{row.company_name}</span> },
    { header: "Contact", cell: (row) => row.contact_name ?? "--" },
    { header: "Phone", cell: (row) => row.phone ?? "--" },
    { header: "Email", cell: (row) => row.email ?? "--" },
    { header: "Terms", cell: (row) => (row.payment_terms_days ? `${row.payment_terms_days}d` : "--") },
    {
      header: "Status",
      cell: (row) => <StatusBadge status={row.is_active ? "active" : "inactive"} />,
    },
  ];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Customers", href: "/customers" }]} />
      <PageHeader
        title="Customers"
        description="Direct shipper relationships outside the broker network."
        primaryAction={{ label: "Add Customer", href: "/customers/new" }}
      />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total Customers" value={totalCount ?? 0} />
        <DesktopKpiBox label="Active" value={activeCount ?? 0} />
        <DesktopKpiBox label="Inactive" value={(totalCount ?? 0) - (activeCount ?? 0)} />
      </DesktopKpiStrip>

      <SearchBar placeholder="Search customers by company name..." />

      {customers.length === 0 ? (
        <EmptyState
          title={q ? "No customers match your search" : "No customers yet"}
          description={q ? "Try a different search term." : "Add a direct customer to book loads for them."}
          action={{ label: "Add Customer", href: "/customers/new" }}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={customers}
          getDetailHref={(row) => `/customers/${row.id}`}
          getDeleteAction={(row) => deleteRecord.bind(null, "customers", row.id, "/customers")}
        />
      )}
    </div>
  );
}
