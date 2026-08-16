import Link from "next/link";
import { redirect, notFound } from "next/navigation";
import { ArrowLeft, FileText } from "lucide-react";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { StatusBadge } from "@/components/ui/status-badge";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

export default async function DriverPortalSettlementDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const identity = await getDriverPortalSession();
  if (!identity) redirect("/driver-portal/login");

  const supabase = createServiceRoleClient();

  // .eq("driver_id", identity.driverId) is the real access control here --
  // a driver requesting another driver's settlement id gets nothing back,
  // never another driver's pay data (spec section 24: "Do not expose...
  // other drivers").
  const { data: settlement } = await supabase
    .from("driver_settlements")
    .select("id, settlement_number, period_start, period_end, status, gross_pay, adjustments_amount, deductions_amount, advances_amount, net_pay, amount_paid, balance_due")
    .eq("id", id)
    .eq("driver_id", identity.driverId)
    .maybeSingle();
  if (!settlement) notFound();

  const [{ data: items }, { data: adjustments }, { data: payments }] = await Promise.all([
    supabase.from("driver_settlement_items").select("load_number, delivery_date, miles, load_rate, pay_method, pay_rate, gross_pay").eq("driver_settlement_id", id).order("delivery_date"),
    supabase.from("driver_settlement_adjustments").select("bucket, category, amount, effective_date").eq("driver_settlement_id", id).order("effective_date"),
    supabase.from("driver_settlement_payments").select("payment_number, paid_date, amount, method, status").eq("driver_settlement_id", id).order("paid_date"),
  ]);

  return (
    <div className="flex flex-1 flex-col gap-4">
      <div className="flex items-center gap-2">
        <Link href="/driver-portal/settlements" className="text-muted-foreground"><ArrowLeft className="size-4" /></Link>
        <h1 className="text-lg font-semibold tracking-tight">{settlement.settlement_number}</h1>
        <StatusBadge status={settlement.status} />
      </div>
      <div className="-mt-2 flex items-center justify-between">
        <p className="text-xs text-muted-foreground">
          {new Date(settlement.period_start + "T00:00:00").toLocaleDateString()} - {new Date(settlement.period_end + "T00:00:00").toLocaleDateString()}
        </p>
        <Link href={`/driver-portal/settlements/${id}/pdf`} target="_blank" className="flex items-center gap-1 text-xs font-medium text-primary">
          <FileText className="size-3.5" /> Settlement PDF
        </Link>
      </div>

      <div className="rounded-2xl border border-border bg-card p-4">
        <div className="grid grid-cols-2 gap-3 text-sm">
          <Field label="Gross Pay" value={money(settlement.gross_pay)} />
          <Field label="Adjustments" value={money(settlement.adjustments_amount)} />
          <Field label="Deductions" value={money(settlement.deductions_amount)} />
          <Field label="Advances" value={money(settlement.advances_amount)} />
          <Field label="Net Pay" value={money(settlement.net_pay)} strong />
          <Field label="Balance Due" value={money(settlement.balance_due)} strong />
        </div>
      </div>

      <div className="rounded-2xl border border-border bg-card p-4">
        <p className="text-sm font-medium">Loads</p>
        <div className="mt-2 space-y-2">
          {(items ?? []).map((it, i) => (
            <div key={i} className="flex items-center justify-between text-sm">
              <span>{it.load_number}</span>
              <span className="text-muted-foreground">{it.delivery_date ? new Date(it.delivery_date + "T00:00:00").toLocaleDateString() : "--"}</span>
              <span className="font-medium">{money(it.gross_pay)}</span>
            </div>
          ))}
          {(!items || items.length === 0) && <p className="text-xs text-muted-foreground">No loads.</p>}
        </div>
      </div>

      {(adjustments ?? []).length > 0 && (
        <div className="rounded-2xl border border-border bg-card p-4">
          <p className="text-sm font-medium">Deductions / Advances</p>
          <div className="mt-2 space-y-2">
            {(adjustments ?? []).map((a, i) => (
              <div key={i} className="flex items-center justify-between text-sm">
                <span className="capitalize text-muted-foreground">{a.category}</span>
                <span className="font-medium">{a.bucket === "adjustment" && a.amount >= 0 ? "+" : "-"}{money(Math.abs(a.amount))}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      <div className="rounded-2xl border border-border bg-card p-4">
        <p className="text-sm font-medium">Payment Status</p>
        <div className="mt-2 space-y-2">
          {(payments ?? []).map((p, i) => (
            <div key={i} className="flex items-center justify-between text-sm">
              <span className="text-muted-foreground">{p.payment_number} -- {new Date(p.paid_date + "T00:00:00").toLocaleDateString()}</span>
              <span className={p.status === "voided" ? "line-through text-muted-foreground" : "font-medium"}>{money(p.amount)}</span>
            </div>
          ))}
          {(!payments || payments.length === 0) && <p className="text-xs text-muted-foreground">No payments recorded yet.</p>}
        </div>
      </div>
    </div>
  );
}

function Field({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div>
      <p className="text-[10.5px] font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={strong ? "font-semibold text-primary" : "font-medium"}>{value}</p>
    </div>
  );
}
