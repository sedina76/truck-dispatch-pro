import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";

type Broker = {
  id: string;
  company_name: string;
  mc_number: string | null;
  contact_name: string | null;
  phone: string | null;
  payment_terms_days: number | null;
  average_days_to_pay: number | null;
  is_blacklisted: boolean;
};

export default async function BrokersPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q } = await searchParams;
  const supabase = await createClient();

  let query = supabase
    .from("brokers")
    .select("id, company_name, mc_number, contact_name, phone, payment_terms_days, average_days_to_pay, is_blacklisted")
    .order("company_name");
  if (q) query = query.ilike("company_name", `%${q}%`);

  const { data } = await query;
  const brokers = (data ?? []) as Broker[];

  const { count: totalCount } = await supabase
    .from("brokers")
    .select("id", { count: "exact", head: true });
  const { count: blacklistedCount } = await supabase
    .from("brokers")
    .select("id", { count: "exact", head: true })
    .eq("is_blacklisted", true);

  const daysToPayValues = brokers
    .map((b) => b.average_days_to_pay)
    .filter((v): v is number => v !== null);
  const avgDaysToPay =
    daysToPayValues.length > 0
      ? (daysToPayValues.reduce((a, b) => a + b, 0) / daysToPayValues.length).toFixed(1)
      : "--";

  const columns: Column<Broker>[] = [
    { header: "Company", cell: (row) => <span className="font-medium">{row.company_name}</span> },
    { header: "MC #", cell: (row) => row.mc_number ?? "--" },
    { header: "Contact", cell: (row) => row.contact_name ?? "--" },
    { header: "Phone", cell: (row) => row.phone ?? "--" },
    { header: "Terms", cell: (row) => (row.payment_terms_days ? `${row.payment_terms_days}d` : "--") },
    { header: "Avg Days to Pay", cell: (row) => row.average_days_to_pay ?? "--" },
    {
      header: "Status",
      cell: (row) => <StatusBadge status={row.is_blacklisted ? "cancelled" : "active"} />,
    },
  ];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Brokers", href: "/brokers" }]} />
      <PageHeader
        title="Brokers"
        description="Freight brokers your loads are sourced from."
        primaryAction={{ label: "Add Broker", href: "/brokers/new" }}
      />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total Brokers" value={totalCount ?? 0} />
        <DesktopKpiBox label="Avg Days to Pay" value={avgDaysToPay} />
        <DesktopKpiBox label="Blacklisted" value={blacklistedCount ?? 0} tone={blacklistedCount ? "danger" : "neutral"} />
        <DesktopKpiBox label="In Good Standing" value={(totalCount ?? 0) - (blacklistedCount ?? 0)} />
      </DesktopKpiStrip>

      <SearchBar placeholder="Search brokers by company name..." />

      {brokers.length === 0 ? (
        <EmptyState
          title={q ? "No brokers match your search" : "No brokers yet"}
          description={q ? "Try a different search term." : "Add a broker to start booking loads from them."}
          action={{ label: "Add Broker", href: "/brokers/new" }}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={brokers}
          getDetailHref={(row) => `/brokers/${row.id}`}
          getDeleteAction={(row) => deleteRecord.bind(null, "brokers", row.id, "/brokers")}
        />
      )}
    </div>
  );
}
