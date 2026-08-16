import Link from "next/link";
import { CheckCircle2 } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { cn } from "@/lib/utils";
import { StatusBadge } from "@/components/ui/status-badge";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopFilterBar, DesktopFilterField, desktopInputClass } from "@/components/desktop/filter-bar";
import { DesktopInspector, DesktopInspectorSection, DesktopInspectorRow, DesktopInspectorEmpty } from "@/components/desktop/inspector";
import { ArAgingChart, type AgingBucketPoint } from "@/components/finance/ar-aging-chart";
import { AGING_BUCKETS, AGING_BUCKET_LABELS, AGING_BUCKET_COLORS } from "@/lib/invoices/effective-status";
import { AGING_FILTER_OPTIONS, CONTACT_METHOD_OPTIONS, formatMoney, type CollectionsQueueRow } from "@/lib/collections/types";
import { filterCollectionsRows } from "@/lib/collections/filter";
import { logContact } from "./actions";

type Summary = {
  total_overdue: number;
  overdue_invoices: number;
  due_this_week: number;
  promises_due: number;
  disputed_amount: number;
  collected_this_month: number;
  avg_days_to_pay: number | null;
};

type SearchParams = {
  filter?: string;
  priority?: string;
  status?: string;
  broker_id?: string;
  customer_id?: string;
  collector_id?: string;
  min_balance?: string;
  q?: string;
  mine?: string;
  more?: string;
  selected?: string;
};

// Finance -> Collections, the reference implementation of the desktop
// redesign. Every KPI/grid/panel value comes from get_collections_queue()/
// get_collections_summary()/broker_payment_risk() (0027_collections.sql) --
// the same canonical functions the Dashboard alert and Invoice Detail
// Collections section use. Filtering beyond broker/customer/collector
// (already RPC args) happens in-memory over the RPC's own result set, same
// pattern the Reports -> A/R Aging page already uses.
export default async function CollectionsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const { filter = "", priority = "", status = "", broker_id, customer_id, collector_id, min_balance, q, mine, selected } = sp;
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const [{ data: summaryData }, { data: queueData }, { data: brokers }, { data: customers }, { data: profiles }, { data: disputeStatusRows }] =
    await Promise.all([
      supabase.rpc("get_collections_summary").single(),
      supabase.rpc("get_collections_queue", {
        p_broker_id: broker_id || null,
        p_customer_id: customer_id || null,
        p_collector_id: mine === "1" ? (user?.id ?? null) : collector_id || null,
      }),
      supabase.from("brokers").select("id, company_name").order("company_name"),
      supabase.from("customers").select("id, company_name").order("company_name"),
      supabase.from("profiles").select("id, full_name").order("full_name"),
      supabase.from("invoice_disputes").select("status"),
    ]);

  const summary = summaryData as Summary | null;
  const queueRows = (queueData ?? []) as CollectionsQueueRow[];
  const allRows = queueRows; // pre-filter snapshot, used by the bottom analytics panels
  // Shared with collections/export/route.ts -- see src/lib/collections/filter.ts.
  const rows = filterCollectionsRows(queueRows, { filter, priority, status, min_balance, q });

  // Preserve every current filter when building the "select this row" /
  // "select this bucket" links below.
  const qs = (overrides: Record<string, string | undefined>) => {
    const params = new URLSearchParams();
    const merged = { filter, priority, status, broker_id, customer_id, collector_id, min_balance, q, mine, selected, ...overrides };
    for (const [k, v] of Object.entries(merged)) if (v) params.set(k, v);
    return `/collections?${params.toString()}`;
  };

  const columns: Column<CollectionsQueueRow>[] = [
    { header: "Priority", cell: (r) => <StatusBadge status={r.priority} /> },
    {
      header: "Invoice #",
      cell: (r) => (
        <Link href={qs({ selected: r.id })} className="font-medium text-primary hover:underline">
          {r.invoice_number}
        </Link>
      ),
    },
    { header: "Load #", cell: (r) => r.load_number ?? "--" },
    { header: "Broker / Customer", cell: (r) => r.broker_name ?? r.customer_name ?? r.bill_to_name },
    { header: "Balance Due", cell: (r) => <span className="font-medium tabular-nums">{formatMoney(r.balance_due)}</span>, className: "text-right" },
    { header: "Due Date", cell: (r) => (r.due_date ? new Date(r.due_date + "T00:00:00").toLocaleDateString() : "--") },
    { header: "Days Past Due", cell: (r) => (r.days_past_due > 0 ? `${r.days_past_due}d` : "--"), className: "text-right" },
    { header: "Aging", cell: (r) => AGING_FILTER_OPTIONS.find((o) => o.value === r.aging_bucket)?.label ?? r.aging_bucket },
    { header: "Promise", cell: (r) => (r.promise_id ? <StatusBadge status={r.promise_effective_status ?? "open"} /> : "--") },
    { header: "Next Follow-Up", cell: (r) => (r.next_follow_up_at ? new Date(r.next_follow_up_at).toLocaleDateString() : "--") },
    { header: "Collector", cell: (r) => r.assigned_collector_name ?? "Unassigned" },
    { header: "Last Contact", cell: (r) => (r.last_contact_at ? new Date(r.last_contact_at).toLocaleDateString() : "--") },
  ];

  // ---- bottom analytics (computed from the unfiltered, broker/customer/
  // collector-scoped queue -- the filter/search bar above only narrows the
  // grid, not these summary panels) ----
  const bucketCounts: Record<string, number> = Object.fromEntries(AGING_BUCKETS.map((b) => [b, 0]));
  const bucketAmounts: Record<string, number> = Object.fromEntries(AGING_BUCKETS.map((b) => [b, 0]));
  for (const r of allRows) {
    bucketCounts[r.aging_bucket] = (bucketCounts[r.aging_bucket] ?? 0) + 1;
    bucketAmounts[r.aging_bucket] = (bucketAmounts[r.aging_bucket] ?? 0) + r.balance_due;
  }
  const chartData: AgingBucketPoint[] = AGING_BUCKETS.map((bucket) => ({
    bucket,
    label: AGING_BUCKET_LABELS[bucket],
    balance: bucketAmounts[bucket] ?? 0,
    count: bucketCounts[bucket] ?? 0,
    color: AGING_BUCKET_COLORS[bucket],
  }));

  const brokenRows = allRows.filter((r) => r.promise_effective_status === "broken");
  const brokenAmount = brokenRows.reduce((s, r) => s + r.balance_due, 0);
  const brokenByBucket = { "1_30": 0, "31_60": 0, "61_90": 0, "90_plus": 0, current: 0 } as Record<string, number>;
  for (const r of brokenRows) brokenByBucket[r.aging_bucket] = (brokenByBucket[r.aging_bucket] ?? 0) + 1;

  const disputeCounts = { open: 0, under_review: 0, resolved: 0, rejected: 0 };
  for (const d of disputeStatusRows ?? []) {
    if (d.status in disputeCounts) disputeCounts[d.status as keyof typeof disputeCounts]++;
  }

  // Internal Payment Risk distribution: brokers currently carrying open
  // exposure get scored by broker_payment_risk(); brokers with historical
  // invoices but nothing outstanding right now are "Good Standing" rather
  // than a fabricated 4th risk tier.
  const exposedBrokerIds = [...new Set(allRows.map((r) => r.broker_id).filter((v): v is string => !!v))];
  const riskResults = await Promise.all(exposedBrokerIds.map((id) => supabase.rpc("broker_payment_risk", { p_broker_id: id })));
  const riskCounts = { high: 0, medium: 0, low: 0 };
  riskResults.forEach((r) => {
    const risk = r.data as string | null;
    if (risk && risk in riskCounts) riskCounts[risk as keyof typeof riskCounts]++;
  });
  // Distinct-broker good standing count: brokers with any non-void invoice
  // but zero rows in the current open queue.
  const { data: allInvoiceBrokerRows } = await supabase.from("invoices").select("broker_id").not("broker_id", "is", null).neq("status", "void");
  const allBrokerIdsWithHistory = new Set((allInvoiceBrokerRows ?? []).map((r) => r.broker_id as string));
  const goodStandingBrokers = [...allBrokerIdsWithHistory].filter((id) => !exposedBrokerIds.includes(id));

  // ---- inspector (master/detail) ----
  let inspectorRow: CollectionsQueueRow | null = null;
  let inspectorActivity: { id: string; contact_method: string; note: string; created_at: string }[] = [];
  if (selected) {
    const [{ data: sel }, { data: activity }] = await Promise.all([
      supabase.rpc("get_collections_queue", { p_invoice_id: selected }),
      supabase
        .from("invoice_collection_activity")
        .select("id, contact_method, note, created_at")
        .eq("invoice_id", selected)
        .order("created_at", { ascending: false })
        .limit(6),
    ]);
    inspectorRow = (sel as CollectionsQueueRow[] | null)?.[0] ?? null;
    inspectorActivity = activity ?? [];
  }

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Collections", href: "/collections" }]} />
      <RegisterDesktopActions
        title="Collections"
        exportOptions={[
          {
            label: "Export CSV (Filtered)",
            href: (() => {
              const params = new URLSearchParams();
              const filters = { filter, priority, status, broker_id, customer_id, collector_id, min_balance, q, mine };
              for (const [k, v] of Object.entries(filters)) if (v) params.set(k, v);
              return `/collections/export?${params.toString()}`;
            })(),
          },
        ]}
      />

      <div>
        <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">Collections</h1>
        <p className="mt-0.5 text-xs text-muted-foreground">Operational work queue for unpaid, overdue, and at-risk invoices.</p>
      </div>

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total Overdue" value={formatMoney(summary?.total_overdue)} tone="danger" href="/collections?filter=overdue" />
        <DesktopKpiBox label="Overdue Invoices" value={summary?.overdue_invoices ?? 0} tone={(summary?.overdue_invoices ?? 0) > 0 ? "danger" : "neutral"} />
        <DesktopKpiBox label="Due This Week" value={formatMoney(summary?.due_this_week)} tone="warning" href="/collections?filter=due_soon" />
        <DesktopKpiBox label="Promises Due" value={summary?.promises_due ?? 0} tone="warning" />
        <DesktopKpiBox label="Disputed Amount" value={formatMoney(summary?.disputed_amount)} tone="danger" href="/collections?filter=disputed" />
        <DesktopKpiBox label="Collected This Month" value={formatMoney(summary?.collected_this_month)} tone="success" href="/payments" />
        <DesktopKpiBox label="Avg Days to Pay" value={summary?.avg_days_to_pay != null ? `${summary.avg_days_to_pay}d` : "N/A"} />
      </DesktopKpiStrip>

      <form method="get">
        {selected && <input type="hidden" name="selected" value={selected} />}
        <DesktopFilterBar>
          <DesktopFilterField label="Search">
            <input name="q" defaultValue={q} placeholder="Invoice, load, broker, customer..." className={cn(desktopInputClass, "w-52")} />
          </DesktopFilterField>
          <DesktopFilterField label="Priority">
            <select name="priority" defaultValue={priority} className={cn(desktopInputClass, "w-28")}>
              <option value="">All</option>
              <option value="urgent">Urgent</option>
              <option value="high">High</option>
              <option value="normal">Normal</option>
              <option value="low">Low</option>
            </select>
          </DesktopFilterField>
          <DesktopFilterField label="Status">
            <select name="status" defaultValue={status} className={cn(desktopInputClass, "w-36")}>
              <option value="">All</option>
              <option value="not_started">Not Started</option>
              <option value="contacted">Contacted</option>
              <option value="follow_up">Follow-Up</option>
              <option value="promise_to_pay">Promise to Pay</option>
              <option value="disputed">Disputed</option>
              <option value="escalated">Escalated</option>
              <option value="resolved">Resolved</option>
            </select>
          </DesktopFilterField>
          <DesktopFilterField label="Collector">
            <select name="collector_id" defaultValue={collector_id ?? ""} className={cn(desktopInputClass, "w-36")}>
              <option value="">All collectors</option>
              {(profiles ?? []).map((p) => (
                <option key={p.id} value={p.id}>{p.full_name}</option>
              ))}
            </select>
          </DesktopFilterField>
          <DesktopFilterField label="Aging">
            <select name="filter" defaultValue={filter} className={cn(desktopInputClass, "w-32")}>
              {AGING_FILTER_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>{o.label}</option>
              ))}
            </select>
          </DesktopFilterField>
          <details className="group">
            <summary className="mb-0.5 inline-flex h-7 cursor-pointer list-none items-center rounded-sm border border-desktop-border px-2 text-[11.5px] font-medium text-muted-foreground hover:bg-desktop-muted">
              More Filters
            </summary>
          </details>
          <DesktopFilterField label="Broker">
            <select name="broker_id" defaultValue={broker_id ?? ""} className={cn(desktopInputClass, "w-36")}>
              <option value="">All brokers</option>
              {(brokers ?? []).map((b) => <option key={b.id} value={b.id}>{b.company_name}</option>)}
            </select>
          </DesktopFilterField>
          <DesktopFilterField label="Customer">
            <select name="customer_id" defaultValue={customer_id ?? ""} className={cn(desktopInputClass, "w-36")}>
              <option value="">All customers</option>
              {(customers ?? []).map((c) => <option key={c.id} value={c.id}>{c.company_name}</option>)}
            </select>
          </DesktopFilterField>
          <DesktopFilterField label="Min Balance">
            <input name="min_balance" type="number" step="0.01" defaultValue={min_balance} className={cn(desktopInputClass, "w-24")} />
          </DesktopFilterField>
          <label className="flex h-7 items-center gap-1.5 text-[11.5px] font-medium">
            <input type="checkbox" name="mine" value="1" defaultChecked={mine === "1"} className="size-3.5" /> My Accounts
          </label>
          <button type="submit" className="h-7 rounded-sm bg-primary px-3 text-[12px] font-medium text-primary-foreground hover:bg-primary-hover">
            Apply
          </button>
          {(filter || priority || status || broker_id || customer_id || collector_id || min_balance || q || mine) && (
            <Link href={qs({ filter: undefined, priority: undefined, status: undefined, broker_id: undefined, customer_id: undefined, collector_id: undefined, min_balance: undefined, q: undefined, mine: undefined })} className="inline-flex h-7 items-center text-[12px] font-medium text-muted-foreground hover:text-foreground">
              Clear
            </Link>
          )}
        </DesktopFilterBar>
      </form>

      <div className="flex items-start gap-3">
        <div className="min-w-0 flex-1">
          {rows.length === 0 ? (
            <EmptyState title="No matching invoices" description="Nothing in the collectible queue matches these filters." />
          ) : (
            <DataTable columns={columns} rows={rows} getDetailHref={(r) => `/invoices/${r.id}`} pageSize={20} />
          )}
        </div>

        <DesktopInspector className="hidden xl:flex">
          {!inspectorRow ? (
            <DesktopInspectorEmpty message="Select an invoice from the queue to see its snapshot, promise, dispute, and recent activity here." />
          ) : (
            <>
              <DesktopPanelHeader title={`Invoice ${inspectorRow.invoice_number}`} dense />
              <DesktopInspectorSection title="Invoice Snapshot">
                <DesktopInspectorRow label="Load #" value={inspectorRow.load_number ?? "--"} />
                <DesktopInspectorRow label="Broker/Customer" value={inspectorRow.broker_name ?? inspectorRow.customer_name ?? inspectorRow.bill_to_name} />
                <DesktopInspectorRow label="Balance Due" value={formatMoney(inspectorRow.balance_due)} />
                <DesktopInspectorRow label="Due Date" value={inspectorRow.due_date ? new Date(inspectorRow.due_date + "T00:00:00").toLocaleDateString() : "--"} />
                <DesktopInspectorRow label="Days Past Due" value={inspectorRow.days_past_due > 0 ? `${inspectorRow.days_past_due}d` : "Current"} />
                <DesktopInspectorRow label="Aging" value={AGING_FILTER_OPTIONS.find((o) => o.value === inspectorRow!.aging_bucket)?.label ?? inspectorRow.aging_bucket} />
                <DesktopInspectorRow label="Collection Status" value={<StatusBadge status={inspectorRow.collection_status} />} />
                <div className="flex gap-2 pt-1">
                  <Link href={`/invoices/${inspectorRow.id}`} className="text-[11.5px] font-medium text-primary hover:underline">
                    View Invoice
                  </Link>
                  <Link href={`/payments/new?invoice_id=${inspectorRow.id}`} className="text-[11.5px] font-medium text-primary hover:underline">
                    Record Payment
                  </Link>
                  <Link
                    href={inspectorRow.broker_id ? `/statements?party=broker:${inspectorRow.broker_id}` : inspectorRow.customer_id ? `/statements?party=customer:${inspectorRow.customer_id}` : "/statements"}
                    className="text-[11.5px] font-medium text-primary hover:underline"
                  >
                    View Statement
                  </Link>
                </div>
              </DesktopInspectorSection>

              <DesktopInspectorSection title="Next Follow-Up">
                <DesktopInspectorRow
                  label="Date"
                  value={inspectorRow.next_follow_up_at ? new Date(inspectorRow.next_follow_up_at).toLocaleDateString() : "--"}
                />
                <DesktopInspectorRow
                  label="Status"
                  value={
                    inspectorRow.next_follow_up_at ? (
                      new Date(inspectorRow.next_follow_up_at) < new Date() ? (
                        <span className="text-desktop-danger">Overdue</span>
                      ) : (
                        <span className="text-desktop-success">Upcoming</span>
                      )
                    ) : (
                      "Not scheduled"
                    )
                  }
                />
                <DesktopInspectorRow label="Method" value={inspectorRow.last_contact_method ?? "--"} />
                <form action={logContact.bind(null, inspectorRow.id)} className="mt-1.5 space-y-1.5 border-t border-desktop-border pt-1.5">
                  <div className="grid grid-cols-2 gap-1.5">
                    <select name="contact_method" className={cn(desktopInputClass, "w-full")}>
                      {CONTACT_METHOD_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
                    </select>
                    <input name="next_follow_up_at" type="date" className={cn(desktopInputClass, "w-full")} />
                  </div>
                  <textarea name="note" required rows={2} placeholder="Log contact note..." className="w-full rounded-sm border border-desktop-border bg-card px-2 py-1 text-[12px]" />
                  <button type="submit" className="h-6 w-full rounded-sm bg-primary text-[11.5px] font-medium text-primary-foreground hover:bg-primary-hover">
                    Log Contact
                  </button>
                </form>
              </DesktopInspectorSection>

              <DesktopInspectorSection title="Payment Promise">
                {inspectorRow.promise_id ? (
                  <>
                    <DesktopInspectorRow label="Status" value={<StatusBadge status={inspectorRow.promise_effective_status ?? "open"} />} />
                    <DesktopInspectorRow label="Promised" value={formatMoney(inspectorRow.promise_amount)} />
                    <DesktopInspectorRow label="Expected" value={inspectorRow.promise_expected_date ? new Date(inspectorRow.promise_expected_date + "T00:00:00").toLocaleDateString() : "--"} />
                  </>
                ) : (
                  <p className="text-[11.5px] text-muted-foreground">No promise on file.</p>
                )}
                <Link href={`/invoices/${inspectorRow.id}`} className="text-[11.5px] font-medium text-primary hover:underline">
                  View Promise
                </Link>
              </DesktopInspectorSection>

              <DesktopInspectorSection title="Dispute Summary">
                <DesktopInspectorRow label="Status" value={inspectorRow.dispute_status ? <StatusBadge status={inspectorRow.dispute_status} /> : "None"} />
                <DesktopInspectorRow label="Disputed" value={formatMoney(inspectorRow.disputed_amount)} />
                <DesktopInspectorRow label="Undisputed" value={formatMoney(inspectorRow.undisputed_amount)} />
                <Link href={`/invoices/${inspectorRow.id}`} className="text-[11.5px] font-medium text-primary hover:underline">
                  View Disputes
                </Link>
              </DesktopInspectorSection>

              <DesktopInspectorSection title="Recent Activity">
                {inspectorActivity.length === 0 ? (
                  <p className="text-[11.5px] text-muted-foreground">No activity logged yet.</p>
                ) : (
                  <ul className="space-y-1.5">
                    {inspectorActivity.map((a) => (
                      <li key={a.id} className="border-b border-desktop-border pb-1.5 last:border-0">
                        <div className="flex items-center justify-between text-[11px] text-muted-foreground">
                          <span className="capitalize font-medium text-desktop-text">{a.contact_method}</span>
                          <span>{new Date(a.created_at).toLocaleDateString()}</span>
                        </div>
                        <p className="truncate text-[11.5px]">{a.note}</p>
                      </li>
                    ))}
                  </ul>
                )}
              </DesktopInspectorSection>
            </>
          )}
        </DesktopInspector>
      </div>

      {/* ---- bottom analytics ---- */}
      <div className="grid grid-cols-1 gap-3 lg:grid-cols-4">
        <DesktopPanel>
          <DesktopPanelHeader title="Aging Summary" />
          <DesktopPanelBody>
            <ArAgingChart data={chartData} />
          </DesktopPanelBody>
        </DesktopPanel>

        <DesktopPanel>
          <DesktopPanelHeader title="Broken Promises" />
          <DesktopPanelBody className="space-y-2">
            <div className="flex items-baseline justify-between">
              <span className="text-2xl font-semibold text-desktop-danger tabular-nums">{brokenRows.length}</span>
              <span className="text-[12px] font-medium tabular-nums">{formatMoney(brokenAmount)}</span>
            </div>
            <div className="space-y-1 text-[11.5px]">
              {AGING_BUCKETS.filter((b) => b !== "current").map((b) => (
                <div key={b} className="flex items-center justify-between">
                  <span className="text-muted-foreground">{AGING_BUCKET_LABELS[b]}</span>
                  <span className="tabular-nums">{brokenByBucket[b] ?? 0}</span>
                </div>
              ))}
            </div>
            <Link href="/collections?filter=broken_promises" className="inline-block text-[11.5px] font-medium text-primary hover:underline">
              View broken promises &rarr;
            </Link>
          </DesktopPanelBody>
        </DesktopPanel>

        <DesktopPanel>
          <DesktopPanelHeader title="Disputes Overview" />
          <DesktopPanelBody className="space-y-1.5 text-[12px]">
            <div className="flex items-center justify-between">
              <span className="flex items-center gap-1.5 text-muted-foreground">Open</span>
              <span className="tabular-nums font-medium text-desktop-danger">{disputeCounts.open}</span>
            </div>
            <div className="flex items-center justify-between">
              <span className="text-muted-foreground">Under Review</span>
              <span className="tabular-nums font-medium text-desktop-warning">{disputeCounts.under_review}</span>
            </div>
            <div className="flex items-center justify-between">
              <span className="text-muted-foreground">Resolved</span>
              <span className="tabular-nums font-medium text-desktop-success">{disputeCounts.resolved}</span>
            </div>
            <div className="flex items-center justify-between">
              <span className="text-muted-foreground">Rejected</span>
              <span className="tabular-nums font-medium">{disputeCounts.rejected}</span>
            </div>
            <Link href="/collections?filter=disputed" className="inline-block pt-1 text-[11.5px] font-medium text-primary hover:underline">
              View disputed invoices &rarr;
            </Link>
          </DesktopPanelBody>
        </DesktopPanel>

        <DesktopPanel>
          <DesktopPanelHeader title="Internal Payment Risk" />
          <DesktopPanelBody className="space-y-1.5 text-[12px]">
            <div className="flex items-center justify-between">
              <span className="text-muted-foreground">High</span>
              <span className="tabular-nums font-medium text-desktop-danger">{riskCounts.high}</span>
            </div>
            <div className="flex items-center justify-between">
              <span className="text-muted-foreground">Medium</span>
              <span className="tabular-nums font-medium text-desktop-warning">{riskCounts.medium}</span>
            </div>
            <div className="flex items-center justify-between">
              <span className="text-muted-foreground">Low</span>
              <span className="tabular-nums font-medium">{riskCounts.low}</span>
            </div>
            <div className="flex items-center justify-between">
              <span className="flex items-center gap-1 text-muted-foreground">
                <CheckCircle2 className="size-3 text-desktop-success" /> Good Standing
              </span>
              <span className="tabular-nums font-medium text-desktop-success">{goodStandingBrokers.length}</span>
            </div>
            <p className="pt-1 text-[10.5px] text-muted-foreground">
              Internal signal from this organization&apos;s own payment history only -- not an external credit score.
            </p>
          </DesktopPanelBody>
        </DesktopPanel>
      </div>
    </div>
  );
}
