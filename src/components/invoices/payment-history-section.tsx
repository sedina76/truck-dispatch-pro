import Link from "next/link";
import { CreditCard } from "lucide-react";
import { StatusBadge } from "@/components/ui/status-badge";

export type PaymentHistoryRow = {
  id: string;
  payment_number: string;
  received_at: string;
  method: string;
  reference_number: string | null;
  amount: number;
  status: string;
  recorded_by_name: string | null;
  notes: string | null;
};

// The single "Payment History" block used on Invoice Detail -- Date /
// Payment # / Method / Reference / Amount / Recorded By / Notes, plus the
// Invoice Total / Total Paid / Balance Due summary the spec asks for.
// Purely presentational: all figures (amount_paid/balance_due) are passed
// in from the invoice row itself, which is the generated-column source of
// truth (0006_financials.sql) -- this component never re-derives them.
export function PaymentHistorySection({
  invoiceId,
  invoiceTotal,
  totalPaid,
  balanceDue,
  payments,
}: {
  invoiceId: string;
  invoiceTotal: number;
  totalPaid: number;
  balanceDue: number;
  payments: PaymentHistoryRow[];
}) {
  return (
    <div className="rounded-xl border border-border bg-card p-4 shadow-elevation-1">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <CreditCard className="size-4 text-primary" />
          <p className="text-sm font-medium">Payment History</p>
        </div>
        <Link
          href={`/payments/new?invoice_id=${invoiceId}`}
          className="inline-flex items-center gap-1.5 rounded-lg bg-primary px-3 py-1.5 text-xs font-medium text-primary-foreground hover:bg-primary-hover"
        >
          Record Payment
        </Link>
      </div>

      <div className="mt-4 grid grid-cols-3 gap-4 border-b border-border pb-4 text-sm">
        <SummaryStat label="Invoice Total" value={invoiceTotal} />
        <SummaryStat label="Total Paid" value={totalPaid} tone="success" />
        <SummaryStat label="Balance Due" value={balanceDue} tone={balanceDue > 0 ? "warning" : "success"} />
      </div>

      {payments.length === 0 ? (
        <p className="mt-3 text-sm text-muted-foreground">No payments recorded yet.</p>
      ) : (
        <div className="mt-3 overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border text-left text-xs font-medium uppercase tracking-wide text-muted-foreground">
                <th className="py-2 pr-3">Date</th>
                <th className="py-2 pr-3">Payment #</th>
                <th className="py-2 pr-3">Method</th>
                <th className="py-2 pr-3">Reference</th>
                <th className="py-2 pr-3 text-right">Amount</th>
                <th className="py-2 pr-3">Recorded By</th>
                <th className="py-2 pr-3">Notes</th>
                <th className="py-2"></th>
              </tr>
            </thead>
            <tbody>
              {payments.map((p) => (
                <tr key={p.id} className={"border-b border-border last:border-0" + (p.status === "voided" ? " opacity-50" : "")}>
                  <td className="py-2 pr-3 whitespace-nowrap">{new Date(p.received_at).toLocaleDateString()}</td>
                  <td className="py-2 pr-3 whitespace-nowrap font-medium">
                    <Link href={`/payments/${p.id}`} className="text-primary hover:underline">
                      {p.payment_number}
                    </Link>
                  </td>
                  <td className="py-2 pr-3 capitalize whitespace-nowrap">{p.method.replace(/_/g, " ")}</td>
                  <td className="py-2 pr-3">{p.reference_number ?? "--"}</td>
                  <td className={"py-2 pr-3 text-right font-medium whitespace-nowrap" + (p.status === "voided" ? " line-through" : "")}>
                    ${Number(p.amount).toLocaleString(undefined, { minimumFractionDigits: 2 })}
                  </td>
                  <td className="py-2 pr-3 whitespace-nowrap">{p.recorded_by_name ?? "--"}</td>
                  <td className="py-2 pr-3 max-w-[160px] truncate" title={p.notes ?? undefined}>{p.notes ?? "--"}</td>
                  <td className="py-2">
                    <StatusBadge status={p.status} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function SummaryStat({ label, value, tone }: { label: string; value: number; tone?: "success" | "warning" }) {
  const toneClass = tone === "success" ? "text-success" : tone === "warning" ? "text-warning" : "";
  return (
    <div>
      <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={"mt-1 text-lg font-semibold " + toneClass}>${Number(value).toLocaleString(undefined, { minimumFractionDigits: 2 })}</p>
    </div>
  );
}
