import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { getLatestDocumentsByEntity } from "@/lib/documents/latest-document";
import { invoiceEffectiveStatus } from "@/lib/invoices/effective-status";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";

type Invoice = {
  id: string;
  invoice_number: string;
  bill_to_name: string;
  status: string;
  total_amount: number;
  amount_paid: number;
  balance_due: number;
  issue_date: string;
  due_date: string | null;
  load_id: string | null;
  loads: { load_number: string } | null;
};

export default async function InvoicesPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q } = await searchParams;
  const supabase = await createClient();

  let query = supabase
    .from("invoices")
    .select("id, invoice_number, bill_to_name, status, total_amount, amount_paid, balance_due, issue_date, due_date, load_id, loads(load_number)")
    .order("issue_date", { ascending: false });
  if (q) query = query.or(`invoice_number.ilike.%${q}%,bill_to_name.ilike.%${q}%`);

  const { data } = await query;
  const invoices = (data ?? []) as unknown as Invoice[];

  // Packet column: same canonical "latest document per load" helper as
  // everywhere else POD status is shown -- see src/lib/documents/latest-document.ts.
  const loadIds = invoices.map((i) => i.load_id).filter((id): id is string => !!id);
  const podByLoadId = await getLatestDocumentsByEntity(supabase, "load", "pod", loadIds);

  const { data: packetRows } = await supabase
    .from("billing_packets")
    .select("invoice_id, version, status")
    .in("invoice_id", invoices.map((i) => i.id))
    .order("version", { ascending: false });
  const latestPacketByInvoiceId = new Map<string, { status: string }>();
  for (const row of packetRows ?? []) {
    if (!latestPacketByInvoiceId.has(row.invoice_id)) latestPacketByInvoiceId.set(row.invoice_id, row);
  }

  function packetLabel(invoice: Invoice): string {
    const pod = invoice.load_id ? podByLoadId.get(invoice.load_id) : null;
    if (!pod || !pod.is_verified) return "Missing POD";
    const packet = latestPacketByInvoiceId.get(invoice.id);
    if (!packet) return "Ready";
    if (packet.status === "sent") return "Sent";
    return "Generated";
  }

  // Outstanding Balance / Overdue: same canonical get_ar_summary() RPC used
  // by Finance -> Accounts Receivable, the main Dashboard, and Reports --
  // one aggregate so this KPI can never disagree with those pages. Paid
  // count is a simple count, not part of that aggregate, so it stays a
  // direct query.
  const [{ data: arSummary }, { count: allInvoicesCount }, { count: paidCount }] = await Promise.all([
    supabase.rpc("get_ar_summary").single(),
    supabase.from("invoices").select("id", { count: "exact", head: true }),
    supabase.from("invoices").select("id", { count: "exact", head: true }).eq("status", "paid"),
  ]);
  const summary = arSummary as {
    total_receivables: number;
    overdue_invoice_count: number;
  } | null;
  const outstanding = Number(summary?.total_receivables ?? 0);
  const overdueCount = Number(summary?.overdue_invoice_count ?? 0);

  const columns: Column<Invoice>[] = [
    { header: "Invoice #", cell: (row) => <span className="font-medium">{row.invoice_number}</span> },
    { header: "Load #", cell: (row) => row.loads?.load_number ?? "--" },
    { header: "Bill To", cell: (row) => row.bill_to_name },
    { header: "Invoice Date", cell: (row) => new Date(row.issue_date).toLocaleDateString() },
    { header: "Due", cell: (row) => (row.due_date ? new Date(row.due_date).toLocaleDateString() : "--") },
    { header: "Amount", cell: (row) => <span className="tabular-nums">${Number(row.total_amount).toLocaleString()}</span>, className: "text-right" },
    { header: "Paid", cell: (row) => <span className="tabular-nums">${Number(row.amount_paid).toLocaleString()}</span>, className: "text-right" },
    { header: "Balance", cell: (row) => <span className="tabular-nums font-medium">${Number(row.balance_due).toLocaleString()}</span>, className: "text-right" },
    {
      header: "Packet",
      cell: (row) => {
        const label = packetLabel(row);
        const toneClass =
          label === "Sent" || label === "Generated" ? "text-desktop-success" : label === "Ready" ? "text-desktop-warning" : "text-desktop-danger";
        return (
          <span className={`inline-flex items-center gap-1.5 text-[12px] font-medium ${toneClass}`}>
            <span className={`size-1.5 shrink-0 ${toneClass.replace("text-", "bg-")}`} />
            {label}
          </span>
        );
      },
    },
    {
      header: "Effective Status",
      cell: (row) => <StatusBadge status={invoiceEffectiveStatus(row.status, row.due_date, Number(row.balance_due))} />,
    },
  ];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Invoices", href: "/invoices" }]} />
      <RegisterDesktopActions title="Invoices" exportOptions={[{ label: "Export CSV (Filtered)", href: `/invoices/export${q ? `?q=${encodeURIComponent(q)}` : ""}` }]} />

      <PageHeader
        title="Invoices"
        description="Bill brokers and customers for completed dispatches."
        primaryAction={{ label: "Create Invoice", href: "/invoices/new" }}
      />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Outstanding Balance" value={`$${outstanding.toLocaleString()}`} href="/accounts-receivable" />
        <DesktopKpiBox label="Overdue" value={overdueCount} tone={overdueCount ? "danger" : "neutral"} href="/collections" />
        <DesktopKpiBox label="Paid" value={paidCount ?? 0} tone="success" />
        <DesktopKpiBox label="Total Invoices" value={allInvoicesCount ?? 0} />
      </DesktopKpiStrip>

      <SearchBar placeholder="Search by invoice number or bill-to name..." />

      {invoices.length === 0 ? (
        <EmptyState
          title={q ? "No invoices match your search" : "No invoices yet"}
          description={q ? "Try a different search term." : "Create an invoice to bill a broker or customer."}
          action={{ label: "Create Invoice", href: "/invoices/new" }}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={invoices}
          getDetailHref={(row) => `/invoices/${row.id}`}
          getDeleteAction={(row) => deleteRecord.bind(null, "invoices", row.id, "/invoices")}
        />
      )}
    </div>
  );
}
