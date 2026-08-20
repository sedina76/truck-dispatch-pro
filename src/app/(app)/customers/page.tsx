import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { FINANCIAL_ROLES, type OrgRole } from "@/lib/auth/require-role";

type Customer = {
  id: string;
  company_name: string;
  contact_name: string | null;
  phone: string | null;
  email: string | null;
  payment_terms_days?: number | null;
  is_active: boolean;
};

// Phase 2G.10 (item 6 full search): same missed-list-page gap as Brokers --
// Customers is Business, open to every role, no layout guard.
export default async function CustomersPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q } = await searchParams;
  const supabase = await createClient();

  const { data: roleData } = await supabase.rpc("current_role");
  const canSeeFinancials = FINANCIAL_ROLES.includes((roleData as OrgRole | null) ?? ("viewer" as OrgRole));

  // Phase 2G.12: payment_terms_days dropped from this select --
  // customer_financials is authoritative now (2G.10 writer cutover);
  // merged in below from a separate query, issued only for canSeeFinancials.
  let query = supabase
    .from("customers")
    .select("id, company_name, contact_name, phone, email, is_active")
    .order("company_name");
  if (q) query = query.ilike("company_name", `%${q}%`);

  const { data } = await query;
  const customersRaw = (data ?? []) as unknown as Omit<Customer, "payment_terms_days">[];

  const termsByCustomerId = new Map<string, number>();
  if (canSeeFinancials && customersRaw.length > 0) {
    const { data: financialsRows } = await supabase.from("customer_financials").select("customer_id, payment_terms_days").in("customer_id", customersRaw.map((c) => c.id));
    for (const row of financialsRows ?? []) if (row.payment_terms_days != null) termsByCustomerId.set(row.customer_id, Number(row.payment_terms_days));
  }
  const customers: Customer[] = customersRaw.map((c) => ({ ...c, payment_terms_days: termsByCustomerId.get(c.id) ?? null }));

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
    ...(canSeeFinancials ? [{ header: "Terms", cell: (row: Customer) => (row.payment_terms_days ? `${row.payment_terms_days}d` : "--") }] : []),
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
