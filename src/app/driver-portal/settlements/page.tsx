import Link from "next/link";
import { redirect } from "next/navigation";
import { ArrowLeft, Wallet } from "lucide-react";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { StatusBadge } from "@/components/ui/status-badge";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

// Driver Portal -> Settlements: ONLY this driver's own settlements
// (spec section 24). Uses the service-role client (drivers have no
// Supabase Auth session, same as every other driver-portal page) but
// explicitly filters .eq("driver_id", identity.driverId) -- the actual
// scoping mechanism here, exactly like driver-portal/page.tsx's dispatch
// query. Never selects SSN/CDL/medical or any other driver's data.
export default async function DriverPortalSettlementsPage() {
  const identity = await getDriverPortalSession();
  if (!identity) redirect("/driver-portal/login");

  const supabase = createServiceRoleClient();
  const { data: settlements } = await supabase
    .from("driver_settlements")
    .select("id, settlement_number, period_start, period_end, status, gross_pay, deductions_amount, advances_amount, net_pay, amount_paid, balance_due")
    .eq("driver_id", identity.driverId)
    .order("period_start", { ascending: false });

  const rows = settlements ?? [];
  const mostRecent = rows[0] ?? null;
  const unpaidBalance = rows.reduce((sum, s) => sum + Math.max(0, Number(s.balance_due)), 0);
  const { data: lastPaymentRows } = await supabase
    .from("driver_settlement_payments")
    .select("paid_date, driver_settlements!inner(driver_id)")
    .eq("driver_settlements.driver_id", identity.driverId)
    .neq("status", "voided")
    .order("paid_date", { ascending: false })
    .limit(1);
  const lastPaymentDate = lastPaymentRows?.[0]?.paid_date ?? null;

  return (
    <div className="flex flex-1 flex-col gap-4">
      <div className="flex items-center gap-2">
        <Link href="/driver-portal" className="text-muted-foreground"><ArrowLeft className="size-4" /></Link>
        <h1 className="text-lg font-semibold tracking-tight">My Settlements</h1>
      </div>

      {mostRecent && (
        <div className="grid grid-cols-2 gap-2.5">
          <SummaryTile label="Most Recent" value={mostRecent.settlement_number} />
          <SummaryTile label="Unpaid Balance" value={money(unpaidBalance)} tone={unpaidBalance > 0 ? "warning" : undefined} />
          <SummaryTile label="Last Payment" value={lastPaymentDate ? new Date(lastPaymentDate + "T00:00:00").toLocaleDateString() : "--"} />
          <SummaryTile label="Settlement Count" value={String(rows.length)} />
        </div>
      )}

      {!settlements || settlements.length === 0 ? (
        <p className="text-sm text-muted-foreground">No settlements yet.</p>
      ) : (
        <div className="space-y-3">
          {settlements.map((s) => (
            <Link key={s.id} href={`/driver-portal/settlements/${s.id}`} className="block rounded-2xl border border-border bg-card p-4">
              <div className="flex items-center justify-between">
                <p className="flex items-center gap-1.5 text-sm font-semibold"><Wallet className="size-3.5 text-primary" />{s.settlement_number}</p>
                <StatusBadge status={s.status} />
              </div>
              <p className="mt-1 text-xs text-muted-foreground">
                {new Date(s.period_start + "T00:00:00").toLocaleDateString()} - {new Date(s.period_end + "T00:00:00").toLocaleDateString()}
              </p>
              <div className="mt-2 flex items-center justify-between text-sm">
                <span className="text-muted-foreground">Net Pay</span>
                <span className="font-semibold">{money(s.net_pay)}</span>
              </div>
              <div className="mt-1 flex items-center justify-between text-xs">
                <span className="text-muted-foreground">Balance</span>
                <span className={s.balance_due > 0 ? "font-medium text-warning" : "text-success"}>{money(s.balance_due)}</span>
              </div>
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}

function SummaryTile({ label, value, tone }: { label: string; value: string; tone?: "warning" }) {
  return (
    <div className="rounded-2xl border border-border bg-card p-3.5">
      <p className={`truncate text-lg font-bold leading-none ${tone === "warning" ? "text-warning" : ""}`}>{value}</p>
      <p className="mt-1 text-[11px] font-medium text-muted-foreground">{label}</p>
    </div>
  );
}
