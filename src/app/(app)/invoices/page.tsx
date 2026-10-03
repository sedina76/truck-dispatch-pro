import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { getLatestDocumentsByEntity } from "@/lib/documents/latest-document";
import { invoiceEffectiveStatus } from "@/lib/invoices/effective-status";
import { BillingSubnav } from "@/components/desktop/billing-subnav";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";
import { liveCarrierDraftIds } from "@/lib/billing/carrier-paid-loads";
import { matchesSearch, safeFilterTerm } from "@/lib/billing/search-match";

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
  /** "ours" = your invoice to the broker; "carrier" = the carrier's invoice ("broker pays the carrier" loads). */
  kind: "ours" | "carrier";
  carrierName?: string | null;
  packet?: string;
};

// A carrier's invoice in the same list (status mapped onto the invoice statuses shown here).
function carrierInvoiceStatus(issuance: string, payment: string): string {
  if (issuance === "voided") return "void";
  if (issuance !== "issued") return "draft";
  if (payment === "paid") return "paid";
  if (payment === "partially_paid" || payment === "partial") return "partially_paid";
  return "sent";
}

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
  // Search: invoice number, bill-to name, or load number (forgiving: "LD-00039" finds LD-100039).
  const term = safeFilterTerm(q ?? "");
  if (term) {
    const { data: loadRows } = await supabase.from("loads").select("id, load_number").order("created_at", { ascending: false }).limit(5000);
    const loadIds = (loadRows ?? []).filter((l) => matchesSearch(l.load_number, term)).map((l) => l.id).slice(0, 300);
    query = query.or(`invoice_number.ilike.%${term}%,bill_to_name.ilike.%${term}%${loadIds.length ? `,load_id.in.(${loadIds.join(",")})` : ""}`);
  }

  const { data } = await query;
  const ours = ((data ?? []) as unknown as Invoice[]).map((i) => ({ ...i, kind: "ours" as const }));
  const invoicesOurs = ours;

  // The carrier's invoices ("broker pays the carrier" loads), listed with yours.
  const { data: carrierRaw } = await supabase
    .from("carrier_invoices")
    .select("id, invoice_number, issuance_status, payment_status, total_amount, amount_paid, due_date, issued_at, created_at, carriers(legal_name, dba_name), brokers:recipient_broker_id(company_name), customers:recipient_customer_id(company_name), carrier_invoice_loads(load_id, loads(load_number))")
    .eq("invoice_document_type", "carrier_freight_invoice")
    .neq("issuance_status", "voided")
    .order("created_at", { ascending: false })
    .limit(500);
  const carrierRows = (carrierRaw ?? []) as unknown as {
    id: string; invoice_number: string | null; issuance_status: string; payment_status: string; total_amount: number; amount_paid: number | null; due_date: string | null; issued_at: string | null; created_at: string;
    carriers: { legal_name: string; dba_name: string | null } | null; brokers: { company_name: string } | null; customers: { company_name: string } | null;
    carrier_invoice_loads: { load_id: string; loads: { load_number: string } | null }[] | null;
  }[];
  const { data: carrierEmails } = carrierRows.length
    ? await supabase.from("email_send_log").select("entity_id").eq("entity_type", "carrier_invoice").eq("status", "sent").in("entity_id", carrierRows.map((c) => c.id))
    : { data: [] as { entity_id: string }[] };
  const emailed = new Set((carrierEmails ?? []).map((e) => String(e.entity_id)));
  // A discarded draft keeps status "draft" but no longer holds its load: hide it.
  const liveDrafts = carrierRows.some((c) => c.issuance_status !== "issued") ? await liveCarrierDraftIds(supabase) : new Set<string>();
  const carrierPods = await getLatestDocumentsByEntity(supabase, "load", "pod", carrierRows.flatMap((c) => (c.carrier_invoice_loads ?? []).map((l) => l.load_id)));
  const needle = term;
  const theirs: Invoice[] = carrierRows
    .map((c) => {
      const loadsOn = c.carrier_invoice_loads ?? [];
      const total = Number(c.total_amount);
      const paid = Number(c.amount_paid ?? 0);
      const issued = c.issuance_status === "issued";
      const podMissing = loadsOn.some((l) => !carrierPods.get(l.load_id)?.is_verified);
      return {
        id: c.id,
        invoice_number: c.invoice_number ?? "Draft",
        bill_to_name: c.brokers?.company_name ?? c.customers?.company_name ?? "--",
        status: carrierInvoiceStatus(c.issuance_status, c.payment_status),
        total_amount: total,
        amount_paid: paid,
        balance_due: Math.max(0, Math.round((total - paid) * 100) / 100),
        issue_date: c.issued_at ?? c.created_at,
        due_date: c.due_date,
        load_id: loadsOn[0]?.load_id ?? null,
        loads: loadsOn.length ? { load_number: loadsOn.map((l) => l.loads?.load_number ?? "").filter(Boolean).join(", ") } : null,
        kind: "carrier" as const,
        carrierName: c.carriers?.dba_name || c.carriers?.legal_name || null,
        packet: !issued ? "Not issued" : podMissing ? "Missing POD" : emailed.has(c.id) ? "Sent" : "Ready",
      };
    })
    .filter((r) => r.status !== "draft" || liveDrafts.has(r.id))
    .filter((r) => !needle || matchesSearch(r.invoice_number, needle) || matchesSearch(r.bill_to_name, needle) || matchesSearch(r.carrierName, needle) || (r.loads?.load_number ?? "").split(", ").some((n) => matchesSearch(n, needle)));

  const invoices = [...invoicesOurs, ...theirs].sort((a, b) => new Date(b.issue_date).getTime() - new Date(a.issue_date).getTime());

  // Packet column: same canonical "latest document per load" helper as
  // everywhere else POD status is shown -- see src/lib/documents/latest-document.ts.
  const loadIds = invoicesOurs.map((i) => i.load_id).filter((id): id is string => !!id);
  const podByLoadId = await getLatestDocumentsByEntity(supabase, "load", "pod", loadIds);

  const { data: packetRows } = await supabase
    .from("billing_packets")
    .select("invoice_id, version, status")
    .in("invoice_id", invoicesOurs.map((i) => i.id))
    .order("version", { ascending: false });
  const latestPacketByInvoiceId = new Map<string, { status: string }>();
  for (const row of packetRows ?? []) {
    if (!latestPacketByInvoiceId.has(row.invoice_id)) latestPacketByInvoiceId.set(row.invoice_id, row);
  }

  function packetLabel(invoice: Invoice): string {
    if (invoice.kind === "carrier") return invoice.packet ?? "Not issued";
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
    {
      header: "Invoice #",
      cell: (row) => (
        <span>
          <span className="font-medium">{row.invoice_number}</span>
          {row.kind === "carrier" && (
            <span className="block text-[10.5px] text-muted-foreground" title="The broker pays the carrier for this load, so this is the carrier's invoice.">
              Carrier&apos;s invoice{row.carrierName ? ` -- ${row.carrierName}` : ""}
            </span>
          )}
        </span>
      ),
    },
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
          label === "Sent" || label === "Generated" ? "text-desktop-success" : label === "Ready" || label === "Not issued" ? "text-desktop-warning" : "text-desktop-danger";
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
      <BillingSubnav />
      <RegisterDesktopActions title="Invoices" exportOptions={[{ label: "Export CSV (Filtered)", href: `/invoices/export${q ? `?q=${encodeURIComponent(q)}` : ""}` }]} />

      <PageHeader
        title="Invoices"
        description={'Every invoice to a broker or customer. When the broker pays the carrier, the invoice is in the carrier\'s name (marked "Carrier\'s invoice").'}
        primaryAction={{ label: "Create Invoice", href: "/invoices/new" }}
      />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Outstanding Balance" value={`$${outstanding.toLocaleString()}`} href="/accounts-receivable" />
        <DesktopKpiBox label="Overdue" value={overdueCount} tone={overdueCount ? "danger" : "neutral"} href="/collections" />
        <DesktopKpiBox label="Paid" value={paidCount ?? 0} tone="success" />
        <DesktopKpiBox label="Total Invoices" value={(allInvoicesCount ?? 0) + theirs.length} />
      </DesktopKpiStrip>

      <SearchBar placeholder="Search by invoice #, load #, or bill-to name..." />

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
          getDetailHref={(row) => (row.kind === "carrier" ? `/carrier-invoices/${row.id}` : `/invoices/${row.id}`)}
          getDeleteAction={(row) => (row.kind === "carrier" ? undefined : deleteRecord.bind(null, "invoices", row.id, "/invoices"))}
        />
      )}
    </div>
  );
}
