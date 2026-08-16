import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { computeStatementData, type StatementKind, type StatementPartyType } from "@/lib/statements/generate";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopFilterBar, DesktopFilterField, desktopInputClass } from "@/components/desktop/filter-bar";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { DesktopInspector, DesktopInspectorSection, DesktopInspectorRow, DesktopInspectorEmpty } from "@/components/desktop/inspector";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmptyState } from "@/components/ui/empty-state";
import { generateStatement } from "./actions";

const AGING_LABELS: Record<string, string> = { current: "Current", "1_30": "1-30 Days", "31_60": "31-60 Days", "61_90": "61-90 Days", "90_plus": "90+ Days" };

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

function resolvePeriod(preset: string, customStart?: string, customEnd?: string, customAsOf?: string) {
  const today = new Date();
  const iso = (d: Date) => d.toISOString().slice(0, 10);
  const startOfMonth = (d: Date) => new Date(d.getFullYear(), d.getMonth(), 1);
  const endOfMonth = (d: Date) => new Date(d.getFullYear(), d.getMonth() + 1, 0);

  if (preset === "this_month") return { start: iso(startOfMonth(today)), end: iso(endOfMonth(today)), asOf: iso(today) };
  if (preset === "last_month") {
    const lastMonth = new Date(today.getFullYear(), today.getMonth() - 1, 1);
    return { start: iso(startOfMonth(lastMonth)), end: iso(endOfMonth(lastMonth)), asOf: iso(endOfMonth(lastMonth)) };
  }
  if (preset === "custom") return { start: customStart || iso(startOfMonth(today)), end: customEnd || iso(today), asOf: customAsOf || iso(today) };
  // "today" / default
  return { start: iso(startOfMonth(today)), end: iso(today), asOf: customAsOf || iso(today) };
}

export default async function StatementsPage({
  searchParams,
}: {
  searchParams: Promise<{ party?: string; type?: string; period?: string; start?: string; end?: string; as_of?: string }>;
}) {
  const sp = await searchParams;
  const supabase = await createClient();

  const [partyType, partyId]: [StatementPartyType | null, string | null] = sp.party
    ? (sp.party.split(":") as [StatementPartyType, string])
    : [null, null];
  const statementType = (sp.type as StatementKind) || "open_balance";
  const periodPreset = sp.period || "this_month";
  const { start: periodStart, end: periodEnd, asOf: asOfDate } = resolvePeriod(periodPreset, sp.start, sp.end, sp.as_of);

  const [{ data: brokers }, { data: customers }] = await Promise.all([
    supabase.from("brokers").select("id, company_name").order("company_name"),
    supabase.from("customers").select("id, company_name").order("company_name"),
  ]);

  return (
    <div className="flex h-full min-h-0 gap-3">
      <div className="flex min-w-0 flex-1 flex-col gap-3">
        <div>
          <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">Statements</h1>
          <p className="mt-0.5 text-xs text-muted-foreground">Broker/Customer billing statements -- open balance, period activity, and aging.</p>
        </div>

        <DesktopFilterBar>
          <form method="GET" className="flex flex-wrap items-end gap-2">
            <DesktopFilterField label="Party">
              <select name="party" defaultValue={sp.party ?? ""} className={desktopInputClass + " w-64"}>
                <option value="">Select a broker or customer...</option>
                <optgroup label="Brokers">
                  {(brokers ?? []).map((b) => (
                    <option key={b.id} value={`broker:${b.id}`}>
                      {b.company_name}
                    </option>
                  ))}
                </optgroup>
                <optgroup label="Customers">
                  {(customers ?? []).map((c) => (
                    <option key={c.id} value={`customer:${c.id}`}>
                      {c.company_name}
                    </option>
                  ))}
                </optgroup>
              </select>
            </DesktopFilterField>

            <DesktopFilterField label="Statement Type">
              <select name="type" defaultValue={statementType} className={desktopInputClass + " w-44"}>
                <option value="open_balance">Open Balance</option>
                <option value="period">Period Activity</option>
                <option value="aging">Aging</option>
              </select>
            </DesktopFilterField>

            <DesktopFilterField label="Period">
              <select name="period" defaultValue={periodPreset} className={desktopInputClass + " w-40"}>
                <option value="today">As Of Today</option>
                <option value="this_month">This Month</option>
                <option value="last_month">Last Month</option>
                <option value="custom">Custom Range</option>
              </select>
            </DesktopFilterField>

            {periodPreset === "custom" && (
              <>
                <DesktopFilterField label="Start Date">
                  <input type="date" name="start" defaultValue={sp.start} className={desktopInputClass} />
                </DesktopFilterField>
                <DesktopFilterField label="End Date">
                  <input type="date" name="end" defaultValue={sp.end} className={desktopInputClass} />
                </DesktopFilterField>
              </>
            )}
            <DesktopFilterField label="As Of Date">
              <input type="date" name="as_of" defaultValue={sp.as_of ?? asOfDate} className={desktopInputClass} />
            </DesktopFilterField>

            <button type="submit" className="h-7 rounded-sm bg-primary px-3 text-[12px] font-medium text-primary-foreground hover:bg-primary-hover">
              Preview
            </button>
            <Link href="/statements" className="h-7 rounded-sm border border-desktop-border px-3 text-[12px] font-medium leading-7 hover:bg-muted">
              Reset
            </Link>
          </form>
        </DesktopFilterBar>

        {!partyType || !partyId ? (
          <StatementHistoryPanel />
        ) : (
          <StatementPreview partyType={partyType} partyId={partyId} statementType={statementType} periodStart={periodStart} periodEnd={periodEnd} asOfDate={asOfDate} />
        )}
      </div>

      {partyType && partyId && <AccountSummaryInspector partyType={partyType} partyId={partyId} />}
    </div>
  );
}

async function StatementPreview({
  partyType,
  partyId,
  statementType,
  periodStart,
  periodEnd,
  asOfDate,
}: {
  partyType: StatementPartyType;
  partyId: string;
  statementType: StatementKind;
  periodStart: string;
  periodEnd: string;
  asOfDate: string;
}) {
  let data;
  try {
    data = await computeStatementData({ partyType, partyId, statementType, periodStart: statementType === "period" ? periodStart : null, periodEnd: statementType === "period" ? periodEnd : null, asOfDate });
  } catch {
    return (
      <DesktopPanel>
        <DesktopPanelBody>
          <p className="text-sm text-warning">That party could not be found.</p>
        </DesktopPanelBody>
      </DesktopPanel>
    );
  }

  return (
    <>
      <DesktopKpiStrip>
        {data.statementType === "period" && <DesktopKpiBox label="Opening Balance" value={money(data.openingBalance)} />}
        {data.statementType === "period" && <DesktopKpiBox label="Period Charges" value={money(data.periodCharges)} tone="warning" />}
        {data.statementType === "period" && <DesktopKpiBox label="Period Payments" value={money(data.periodPayments)} tone="success" />}
        <DesktopKpiBox label="Closing Balance" value={money(data.closingBalance)} tone="primary" />
        <DesktopKpiBox label="Total Outstanding" value={money(data.aging.total_outstanding)} />
      </DesktopKpiStrip>

      <DesktopPanel className="flex min-h-0 flex-1 flex-col">
        <DesktopPanelHeader
          title={`Statement Preview -- ${data.party.company_name}`}
          actions={
            <form action={generateStatement} className="flex items-center gap-2">
              <input type="hidden" name="party_type" value={partyType} />
              <input type="hidden" name="party_id" value={partyId} />
              <input type="hidden" name="statement_type" value={statementType} />
              {statementType === "period" && <input type="hidden" name="period_start" value={periodStart} />}
              {statementType === "period" && <input type="hidden" name="period_end" value={periodEnd} />}
              <input type="hidden" name="as_of_date" value={asOfDate} />
              <button type="submit" className="rounded-sm bg-desktop-header-text/15 px-2 py-0.5 text-[11px] font-semibold hover:bg-desktop-header-text/25">
                Generate Statement
              </button>
            </form>
          }
        />
        <DesktopPanelBody className="min-h-0 flex-1 overflow-auto">
          {data.statementType === "period" ? <TransactionLedger data={data} /> : <OpenInvoiceTable rows={data.openInvoices} />}
        </DesktopPanelBody>
      </DesktopPanel>

      <DesktopPanel>
        <DesktopPanelHeader title="Aging Summary" />
        <DesktopPanelBody>
          <div className="grid grid-cols-5 gap-3 text-[12.5px]">
            {(["current", "1_30", "31_60", "61_90", "90_plus"] as const).map((bucket) => {
              const key = bucket === "current" ? "current" : bucket === "1_30" ? "bucket_1_30" : bucket === "31_60" ? "bucket_31_60" : bucket === "61_90" ? "bucket_61_90" : "bucket_90_plus";
              return (
                <div key={bucket}>
                  <p className="text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">{AGING_LABELS[bucket]}</p>
                  <p className="mt-1 font-semibold text-desktop-text tabular-nums">{money((data.aging as unknown as Record<string, number>)[key])}</p>
                </div>
              );
            })}
          </div>
          <p className="mt-2 text-[10.5px] text-muted-foreground">Bucket totals sum to Total Outstanding above -- same canonical aging function as Accounts Receivable.</p>
        </DesktopPanelBody>
      </DesktopPanel>
    </>
  );
}

function TransactionLedger({ data }: { data: Awaited<ReturnType<typeof computeStatementData>> }) {
  if (data.transactions.length === 0) {
    return <EmptyState title="No activity in this period" description="No invoices were issued and no payments were received in this window." />;
  }
  return (
    <table className="w-full text-[12.5px]">
      <thead>
        <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
          <th className="py-1.5 pr-3">Date</th>
          <th className="py-1.5 pr-3">Type</th>
          <th className="py-1.5 pr-3">Reference</th>
          <th className="py-1.5 pr-3">Load #</th>
          <th className="py-1.5 pr-3">Description</th>
          <th className="py-1.5 pr-3 text-right">Charges</th>
          <th className="py-1.5 pr-3 text-right">Payments</th>
          <th className="py-1.5 text-right">Balance</th>
        </tr>
      </thead>
      <tbody>
        {data.transactions.map((t, i) => (
          <tr key={i} className={"border-b border-desktop-border last:border-0" + (t.is_voided ? " opacity-50" : "")}>
            <td className="py-1.5 pr-3 whitespace-nowrap">{new Date(t.txn_date + "T00:00:00").toLocaleDateString()}</td>
            <td className="py-1.5 pr-3 capitalize">{t.txn_type.replace("_", " ")}</td>
            <td className="py-1.5 pr-3 font-medium">{t.reference}</td>
            <td className="py-1.5 pr-3">{t.load_number ?? "--"}</td>
            <td className="py-1.5 pr-3">
              {t.description}
              {t.is_voided && <span className="ml-1.5 text-[10px] font-semibold text-danger">VOIDED</span>}
            </td>
            <td className="py-1.5 pr-3 text-right tabular-nums">{t.charge_amount > 0 ? money(t.charge_amount) : "--"}</td>
            <td className="py-1.5 pr-3 text-right tabular-nums">{t.payment_amount > 0 ? money(t.payment_amount) : "--"}</td>
            <td className="py-1.5 text-right font-medium tabular-nums">{money(t.running_balance)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function OpenInvoiceTable({ rows }: { rows: Awaited<ReturnType<typeof computeStatementData>>["openInvoices"] }) {
  if (rows.length === 0) {
    return <EmptyState title="No open invoices" description="Every non-void invoice for this party is fully paid as of this date." />;
  }
  return (
    <table className="w-full text-[12.5px]">
      <thead>
        <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
          <th className="py-1.5 pr-3">Invoice #</th>
          <th className="py-1.5 pr-3">Load #</th>
          <th className="py-1.5 pr-3">Invoice Date</th>
          <th className="py-1.5 pr-3">Due Date</th>
          <th className="py-1.5 pr-3 text-right">Original</th>
          <th className="py-1.5 pr-3 text-right">Paid</th>
          <th className="py-1.5 pr-3 text-right">Balance</th>
          <th className="py-1.5 pr-3">Days Past Due</th>
          <th className="py-1.5">Status</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((inv) => (
          <tr key={inv.id} className="border-b border-desktop-border last:border-0">
            <td className="py-1.5 pr-3 font-medium">
              <Link href={`/invoices/${inv.id}`} className="text-primary hover:underline">
                {inv.invoice_number}
              </Link>
            </td>
            <td className="py-1.5 pr-3">{inv.load_number ?? "--"}</td>
            <td className="py-1.5 pr-3 whitespace-nowrap">{new Date(inv.issue_date + "T00:00:00").toLocaleDateString()}</td>
            <td className="py-1.5 pr-3 whitespace-nowrap">{inv.due_date ? new Date(inv.due_date + "T00:00:00").toLocaleDateString() : "--"}</td>
            <td className="py-1.5 pr-3 text-right tabular-nums">{money(inv.total_amount)}</td>
            <td className="py-1.5 pr-3 text-right tabular-nums">{money(inv.amount_paid)}</td>
            <td className="py-1.5 pr-3 text-right font-medium tabular-nums">{money(inv.balance_due)}</td>
            <td className="py-1.5 pr-3">{inv.days_past_due > 0 ? `${inv.days_past_due}d` : "--"}</td>
            <td className="py-1.5">
              <StatusBadge status={inv.effective_status} />
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

async function AccountSummaryInspector({ partyType, partyId }: { partyType: StatementPartyType; partyId: string }) {
  const supabase = await createClient();
  const brokerId = partyType === "broker" ? partyId : null;
  const customerId = partyType === "customer" ? partyId : null;

  const [{ data: summary }, { data: lastPayment }, { data: lastStatement }] = await Promise.all([
    supabase.rpc("get_party_ar_summary", { p_broker_id: brokerId, p_customer_id: customerId }).single(),
    supabase
      .from("payments")
      .select("amount, received_at, invoices!inner(broker_id, customer_id)")
      .eq("status", "posted")
      .eq(brokerId ? "invoices.broker_id" : "invoices.customer_id", partyId)
      .order("received_at", { ascending: false })
      .limit(1)
      .maybeSingle(),
    supabase
      .from("statements")
      .select("statement_number, generated_at")
      .eq(brokerId ? "broker_id" : "customer_id", partyId)
      .order("generated_at", { ascending: false })
      .limit(1)
      .maybeSingle(),
  ]);

  const s = summary as {
    outstanding: number;
    past_due: number;
    oldest_unpaid_due_date: string | null;
    avg_days_to_pay: number | null;
    open_invoices: number;
  } | null;

  return (
    <DesktopInspector>
      <DesktopInspectorSection title="Account Summary">
        <DesktopInspectorRow label="Current Balance" value={money(s?.outstanding ?? 0)} />
        <DesktopInspectorRow label="Past Due" value={money(s?.past_due ?? 0)} />
        <DesktopInspectorRow label="Open Invoices" value={String(s?.open_invoices ?? 0)} />
        <DesktopInspectorRow label="Oldest Open Invoice" value={s?.oldest_unpaid_due_date ? new Date(s.oldest_unpaid_due_date + "T00:00:00").toLocaleDateString() : "--"} />
        <DesktopInspectorRow label="Avg Days to Pay" value={s?.avg_days_to_pay != null ? `${s.avg_days_to_pay}d` : "Not enough data"} />
      </DesktopInspectorSection>
      <DesktopInspectorSection title="Last Payment">
        {lastPayment ? (
          <>
            <DesktopInspectorRow label="Amount" value={money(Number(lastPayment.amount))} />
            <DesktopInspectorRow label="Date" value={new Date(lastPayment.received_at).toLocaleDateString()} />
          </>
        ) : (
          <DesktopInspectorEmpty message="No payments on file." />
        )}
      </DesktopInspectorSection>
      <DesktopInspectorSection title="Last Statement">
        {lastStatement ? (
          <>
            <DesktopInspectorRow label="Number" value={lastStatement.statement_number} />
            <DesktopInspectorRow label="Generated" value={new Date(lastStatement.generated_at).toLocaleDateString()} />
          </>
        ) : (
          <DesktopInspectorEmpty message="No statements generated yet." />
        )}
      </DesktopInspectorSection>
    </DesktopInspector>
  );
}

async function StatementHistoryPanel() {
  const supabase = await createClient();
  const { data: statements } = await supabase
    .from("statements")
    .select("id, statement_number, party_type, statement_type, period_start, period_end, as_of_date, opening_balance, closing_balance, generated_at, status, brokers(company_name), customers(company_name)")
    .order("generated_at", { ascending: false })
    .limit(50);

  const rows = (statements ?? []) as unknown as {
    id: string;
    statement_number: string;
    party_type: string;
    statement_type: string;
    period_start: string | null;
    period_end: string | null;
    as_of_date: string;
    opening_balance: number;
    closing_balance: number;
    generated_at: string;
    status: string;
    brokers: { company_name: string } | null;
    customers: { company_name: string } | null;
  }[];

  return (
    <DesktopPanel className="flex min-h-0 flex-1 flex-col">
      <DesktopPanelHeader title="Statement History" />
      <DesktopPanelBody className="min-h-0 flex-1 overflow-auto">
        {rows.length === 0 ? (
          <EmptyState title="No statements generated yet" description="Select a broker or customer above, choose a statement type, and generate one." />
        ) : (
          <table className="w-full text-[12.5px]">
            <thead>
              <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                <th className="py-1.5 pr-3">Statement #</th>
                <th className="py-1.5 pr-3">Party</th>
                <th className="py-1.5 pr-3">Type</th>
                <th className="py-1.5 pr-3">Period / As Of</th>
                <th className="py-1.5 pr-3 text-right">Opening</th>
                <th className="py-1.5 pr-3 text-right">Closing</th>
                <th className="py-1.5 pr-3">Generated</th>
                <th className="py-1.5 pr-3">Status</th>
                <th className="py-1.5"></th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id} className="border-b border-desktop-border last:border-0">
                  <td className="py-1.5 pr-3 font-medium">{r.statement_number}</td>
                  <td className="py-1.5 pr-3">{r.brokers?.company_name ?? r.customers?.company_name ?? "--"}</td>
                  <td className="py-1.5 pr-3 capitalize">{r.statement_type.replace("_", " ")}</td>
                  <td className="py-1.5 pr-3 whitespace-nowrap">
                    {r.statement_type === "period"
                      ? `${new Date(r.period_start! + "T00:00:00").toLocaleDateString()} - ${new Date(r.period_end! + "T00:00:00").toLocaleDateString()}`
                      : new Date(r.as_of_date + "T00:00:00").toLocaleDateString()}
                  </td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.opening_balance)}</td>
                  <td className="py-1.5 pr-3 text-right font-medium tabular-nums">{money(r.closing_balance)}</td>
                  <td className="py-1.5 pr-3 whitespace-nowrap">{new Date(r.generated_at).toLocaleDateString()}</td>
                  <td className="py-1.5 pr-3">
                    <StatusBadge status={r.status} />
                  </td>
                  <td className="py-1.5">
                    <Link href={`/statements/${r.id}`} className="text-xs font-medium text-primary hover:underline">
                      View
                    </Link>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </DesktopPanelBody>
    </DesktopPanel>
  );
}
