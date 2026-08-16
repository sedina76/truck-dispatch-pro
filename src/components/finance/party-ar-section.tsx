import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { StatusBadge } from "@/components/ui/status-badge";
import { formatMoney } from "@/lib/collections/types";

type PartyArSummary = {
  total_billed: number;
  total_paid: number;
  outstanding: number;
  past_due: number;
  open_invoices: number;
  paid_invoices: number;
  oldest_unpaid_due_date: string | null;
  avg_days_to_pay: number | null;
};

type QueueRow = {
  id: string;
  invoice_number: string;
  due_date: string | null;
  balance_due: number;
  effective_status: string;
  days_past_due: number;
  last_contact_at: string | null;
  next_follow_up_at: string | null;
  promise_effective_status: string | null;
  dispute_status: string | null;
};

const money = formatMoney;

// Shared Broker/Customer "Accounts Receivable" + "Collections" sections --
// pass exactly one of brokerId/customerId (never both), which
// get_party_ar_summary() and get_collections_queue() use to scope every
// figure to that one party via RLS-protected queries. Same RPCs the
// Finance A/R dashboard and Collections queue use, so a broker's numbers
// here always foot to their invoices' actual totals -- never a separately-
// tracked balance that could drift. The Collections block below is built
// directly onto this same component (not a parallel one) per spec --
// get_collections_queue() is a superset of what get_ar_invoices() returned
// here, so this also replaces that call rather than adding a second one.
// avg_days_to_pay is null (not 0) until at least one invoice has actually
// been paid; rendered as "Not enough data" rather than fabricated.
export async function PartyArSection({ brokerId, customerId }: { brokerId?: string; customerId?: string }) {
  const supabase = await createClient();

  const [{ data: summaryData }, { data: queueData }, riskRes, lastPaymentRes, lastStatementRes] = await Promise.all([
    supabase.rpc("get_party_ar_summary", { p_broker_id: brokerId ?? null, p_customer_id: customerId ?? null }).single(),
    supabase.rpc("get_collections_queue", { p_broker_id: brokerId ?? null, p_customer_id: customerId ?? null }),
    // "Internal Payment Risk" is explicitly a broker-side signal (spec
    // section 15) -- never computed/shown for a direct customer.
    brokerId ? supabase.rpc("broker_payment_risk", { p_broker_id: brokerId }) : Promise.resolve({ data: null }),
    supabase
      .from("payments")
      .select("amount, received_at, invoices!inner(broker_id, customer_id)")
      .eq("status", "posted")
      .eq(brokerId ? "invoices.broker_id" : "invoices.customer_id", brokerId ?? customerId)
      .order("received_at", { ascending: false })
      .limit(1)
      .maybeSingle(),
    supabase
      .from("statements")
      .select("statement_number, generated_at")
      .eq(brokerId ? "broker_id" : "customer_id", brokerId ?? customerId)
      .order("generated_at", { ascending: false })
      .limit(1)
      .maybeSingle(),
  ]);
  const summary = summaryData as PartyArSummary | null;
  const rows = (queueData ?? []) as QueueRow[];
  const openInvoices = rows.filter((i) => i.balance_due > 0);
  const risk = riskRes.data as string | null;
  const lastPayment = lastPaymentRes.data as { amount: number; received_at: string } | null;
  const lastStatement = lastStatementRes.data as { statement_number: string; generated_at: string } | null;

  if (!summary || (summary.total_billed === 0 && summary.open_invoices === 0 && summary.paid_invoices === 0)) {
    return (
      <div className="rounded-xl border border-border bg-card p-4 shadow-elevation-1">
        <p className="text-sm font-medium">Accounts Receivable</p>
        <p className="mt-2 text-sm text-muted-foreground">No invoices on file for this party yet.</p>
      </div>
    );
  }

  const openDisputes = rows.filter((r) => r.dispute_status === "open" || r.dispute_status === "under_review").length;
  const brokenPromises = rows.filter((r) => r.promise_effective_status === "broken").length;
  const lastContactAt = rows
    .map((r) => r.last_contact_at)
    .filter((v): v is string => !!v)
    .sort()
    .pop();
  const nextFollowUpAt = rows
    .map((r) => r.next_follow_up_at)
    .filter((v): v is string => !!v)
    .sort()[0];

  return (
    <div className="space-y-4">
      <div className="rounded-xl border border-border bg-card p-4 shadow-elevation-1">
        <div className="flex items-center justify-between">
          <p className="text-sm font-medium">Accounts Receivable</p>
          <div className="flex items-center gap-3">
            {risk && (
              <span className="text-xs text-muted-foreground">
                Internal Payment Risk: <StatusBadge status={risk} />
              </span>
            )}
            <Link
              href={brokerId ? `/statements?party=broker:${brokerId}` : `/statements?party=customer:${customerId}`}
              className="inline-flex h-7 items-center rounded-sm border border-desktop-border px-2.5 text-xs font-medium hover:bg-muted"
            >
              View Statement
            </Link>
            {summary.outstanding > 0 && (
              <Link
                href={brokerId ? `/payments/new?broker_id=${brokerId}` : `/payments/new?customer_id=${customerId}`}
                className="inline-flex h-7 items-center rounded-sm bg-primary px-2.5 text-xs font-medium text-primary-foreground hover:bg-primary-hover"
              >
                Record Payment
              </Link>
            )}
          </div>
        </div>

        <div className="mt-3 grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-6">
          <Stat label="Total Billed" value={money(summary.total_billed)} />
          <Stat label="Total Paid" value={money(summary.total_paid)} tone="success" />
          <Stat label="Outstanding" value={money(summary.outstanding)} tone={summary.outstanding > 0 ? "warning" : "success"} />
          <Stat label="Past Due" value={money(summary.past_due)} tone={summary.past_due > 0 ? "danger" : "success"} />
          <Stat label="Open Invoices" value={String(summary.open_invoices)} />
          <Stat
            label="Avg Days to Pay"
            value={summary.avg_days_to_pay !== null ? `${summary.avg_days_to_pay}d` : "Not enough data"}
          />
        </div>

        <div className="mt-3 grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-6 border-t border-border pt-3">
          <Stat label="Paid Invoices" value={String(summary.paid_invoices)} />
          <Stat
            label="Oldest Unpaid Invoice"
            value={summary.oldest_unpaid_due_date ? new Date(summary.oldest_unpaid_due_date + "T00:00:00").toLocaleDateString() : "--"}
          />
          <Stat label="Last Payment" value={lastPayment ? `${money(Number(lastPayment.amount))} (${new Date(lastPayment.received_at).toLocaleDateString()})` : "None yet"} />
          <Stat label="Last Statement" value={lastStatement ? `${lastStatement.statement_number} (${new Date(lastStatement.generated_at).toLocaleDateString()})` : "None yet"} />
        </div>

        {openInvoices.length > 0 && (
          <div className="mt-4 border-t border-border pt-3">
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Open Invoices</p>
            <ul className="mt-2 divide-y divide-border">
              {openInvoices.map((inv) => (
                <li key={inv.id} className="flex items-center justify-between py-2 text-sm">
                  <Link href={`/invoices/${inv.id}`} className="font-medium text-primary hover:underline">
                    {inv.invoice_number}
                  </Link>
                  <span className="text-muted-foreground">
                    {inv.due_date ? `Due ${new Date(inv.due_date + "T00:00:00").toLocaleDateString()}` : "No due date"}
                  </span>
                  <span className="font-medium">{money(inv.balance_due)}</span>
                  <StatusBadge status={inv.effective_status} />
                  <Link href={`/payments/new?invoice_id=${inv.id}`} className="text-xs font-medium text-primary hover:underline">
                    Record Payment
                  </Link>
                </li>
              ))}
            </ul>
          </div>
        )}
      </div>

      <div className="rounded-xl border border-border bg-card p-4 shadow-elevation-1">
        <p className="text-sm font-medium">Collections</p>
        <div className="mt-3 grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-6">
          <Stat label="Outstanding Balance" value={money(summary.outstanding)} tone={summary.outstanding > 0 ? "warning" : "success"} />
          <Stat label="Past Due Balance" value={money(summary.past_due)} tone={summary.past_due > 0 ? "danger" : "success"} />
          <Stat
            label="Oldest Unpaid Invoice"
            value={summary.oldest_unpaid_due_date ? new Date(summary.oldest_unpaid_due_date + "T00:00:00").toLocaleDateString() : "--"}
          />
          <Stat label="Avg Days to Pay" value={summary.avg_days_to_pay !== null ? `${summary.avg_days_to_pay}d` : "Not enough data"} />
          <Stat label="Open Disputes" value={String(openDisputes)} tone={openDisputes > 0 ? "danger" : "success"} />
          <Stat label="Broken Promises" value={String(brokenPromises)} tone={brokenPromises > 0 ? "danger" : "success"} />
        </div>
        <div className="mt-3 grid grid-cols-2 gap-4 border-t border-border pt-3">
          <Stat label="Last Contact" value={lastContactAt ? new Date(lastContactAt).toLocaleDateString() : "--"} />
          <Stat label="Next Follow-Up" value={nextFollowUpAt ? new Date(nextFollowUpAt).toLocaleDateString() : "--"} />
        </div>
        <Link
          href={brokerId ? `/collections?broker_id=${brokerId}` : `/collections?customer_id=${customerId}`}
          className="mt-3 inline-block text-xs font-medium text-primary hover:underline"
        >
          View in Collections Queue &rarr;
        </Link>
      </div>
    </div>
  );
}

function Stat({ label, value, tone }: { label: string; value: string; tone?: "success" | "warning" | "danger" }) {
  const toneClass = tone === "success" ? "text-success" : tone === "warning" ? "text-warning" : tone === "danger" ? "text-danger" : "";
  return (
    <div>
      <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={"mt-1 text-base font-semibold " + toneClass}>{value}</p>
    </div>
  );
}
