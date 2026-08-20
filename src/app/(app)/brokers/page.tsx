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

type Broker = {
  id: string;
  company_name: string;
  mc_number: string | null;
  contact_name: string | null;
  phone: string | null;
  payment_terms_days?: number | null;
  average_days_to_pay?: number | null;
  is_blacklisted: boolean;
};

// Phase 2G.10 (item 6 full search): Brokers list is Business, open to
// every role, no layout guard -- payment_terms_days/average_days_to_pay
// were unconditional (list page, missed in the 2G.9 sweep which only
// covered /brokers/[id]).
export default async function BrokersPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q } = await searchParams;
  const supabase = await createClient();

  const { data: roleData } = await supabase.rpc("current_role");
  const canSeeFinancials = FINANCIAL_ROLES.includes((roleData as OrgRole | null) ?? ("viewer" as OrgRole));

  // Phase 2G.12: payment_terms_days/average_days_to_pay dropped from this
  // select -- broker_financials is authoritative now (2G.10 writer
  // cutover for payment_terms_days; average_days_to_pay has never had a
  // writer in either location, but must still be read from the extension
  // table since brokers.average_days_to_pay is scheduled for removal by
  // 0069). Merged in below, issued only for canSeeFinancials.
  let query = supabase
    .from("brokers")
    .select("id, company_name, mc_number, contact_name, phone, is_blacklisted")
    .order("company_name");
  if (q) query = query.ilike("company_name", `%${q}%`);

  const { data } = await query;
  const brokersRaw = (data ?? []) as unknown as Omit<Broker, "payment_terms_days" | "average_days_to_pay">[];

  const financialsByBrokerId = new Map<string, { payment_terms_days: number | null; average_days_to_pay: number | null }>();
  if (canSeeFinancials && brokersRaw.length > 0) {
    const { data: financialsRows } = await supabase
      .from("broker_financials")
      .select("broker_id, payment_terms_days, average_days_to_pay")
      .in("broker_id", brokersRaw.map((b) => b.id));
    for (const row of financialsRows ?? []) financialsByBrokerId.set(row.broker_id, row);
  }
  const brokers: Broker[] = brokersRaw.map((b) => ({
    ...b,
    payment_terms_days: financialsByBrokerId.get(b.id)?.payment_terms_days ?? null,
    average_days_to_pay: financialsByBrokerId.get(b.id)?.average_days_to_pay ?? null,
  }));

  const { count: totalCount } = await supabase
    .from("brokers")
    .select("id", { count: "exact", head: true });
  const { count: blacklistedCount } = await supabase
    .from("brokers")
    .select("id", { count: "exact", head: true })
    .eq("is_blacklisted", true);

  const daysToPayValues = brokers
    .map((b) => b.average_days_to_pay)
    .filter((v): v is number => v != null);
  const avgDaysToPay =
    daysToPayValues.length > 0
      ? (daysToPayValues.reduce((a, b) => a + b, 0) / daysToPayValues.length).toFixed(1)
      : "--";

  const columns: Column<Broker>[] = [
    { header: "Company", cell: (row) => <span className="font-medium">{row.company_name}</span> },
    { header: "MC #", cell: (row) => row.mc_number ?? "--" },
    { header: "Contact", cell: (row) => row.contact_name ?? "--" },
    { header: "Phone", cell: (row) => row.phone ?? "--" },
    ...(canSeeFinancials
      ? [
          { header: "Terms", cell: (row: Broker) => (row.payment_terms_days ? `${row.payment_terms_days}d` : "--") },
          { header: "Avg Days to Pay", cell: (row: Broker) => row.average_days_to_pay ?? "--" },
        ]
      : []),
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
        {canSeeFinancials && <DesktopKpiBox label="Avg Days to Pay" value={avgDaysToPay} />}
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
