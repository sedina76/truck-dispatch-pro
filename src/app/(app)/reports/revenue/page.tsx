import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { KpiRow, KpiCard } from "@/components/ui/kpi-card";
import { EmptyState } from "@/components/ui/empty-state";

export default async function RevenueReportPage() {
  const supabase = await createClient();

  // Phase 2G.12 (found during the final legacy-column search): `rate`
  // dropped from this select -- load_financials is authoritative now
  // (0068 writer cutover). No additional role gating needed -- this whole
  // route is already layout-guarded to FINANCIAL_ROLES (reports/layout.tsx).
  const [{ data: loads }, { data: payments }, { data: loadFinancials }] = await Promise.all([
    supabase.from("loads").select("id, created_at"),
    // status = 'posted' only -- a voided payment was never really
    // collected, matching the same rule get_ar_summary() uses everywhere
    // else this is calculated.
    supabase.from("payments").select("amount, received_at").eq("status", "posted"),
    supabase.from("load_financials").select("load_id, rate"),
  ]);
  const rateByLoadId = new Map((loadFinancials ?? []).map((r) => [r.load_id, Number(r.rate)]));

  const months: { key: string; label: string; booked: number; collected: number }[] = [];
  for (let i = 5; i >= 0; i--) {
    const d = new Date();
    d.setDate(1);
    d.setMonth(d.getMonth() - i);
    months.push({
      key: `${d.getFullYear()}-${d.getMonth()}`,
      label: d.toLocaleString("en-US", { month: "short", year: "numeric" }),
      booked: 0,
      collected: 0,
    });
  }

  for (const load of loads ?? []) {
    const d = new Date(load.created_at);
    const key = `${d.getFullYear()}-${d.getMonth()}`;
    const month = months.find((m) => m.key === key);
    if (month) month.booked += rateByLoadId.get(load.id) ?? 0;
  }
  for (const payment of payments ?? []) {
    const d = new Date(payment.received_at);
    const key = `${d.getFullYear()}-${d.getMonth()}`;
    const month = months.find((m) => m.key === key);
    if (month) month.collected += Number(payment.amount);
  }

  const totalBooked = months.reduce((sum, m) => sum + m.booked, 0);
  const totalCollected = months.reduce((sum, m) => sum + m.collected, 0);
  const maxValue = Math.max(1, ...months.flatMap((m) => [m.booked, m.collected]));

  return (
    <div className="space-y-6">
      <PageHeader title="Revenue Report" description="Revenue booked and collected over the last 6 months." />

      <KpiRow>
        <KpiCard label="Booked (6mo)" value={`$${totalBooked.toLocaleString()}`} />
        <KpiCard label="Collected (6mo)" value={`$${totalCollected.toLocaleString()}`} />
        <KpiCard label="Collection Rate" value={totalBooked ? `${Math.round((totalCollected / totalBooked) * 100)}%` : "--"} />
      </KpiRow>

      {totalBooked === 0 && totalCollected === 0 ? (
        <EmptyState title="No revenue data yet" description="Booked loads and collected payments will chart here." />
      ) : (
        <div className="rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] p-4">
          <div className="flex items-end gap-6 overflow-x-auto pb-2">
            {months.map((m) => (
              <div key={m.key} className="flex flex-col items-center gap-2">
                <div className="flex h-40 items-end gap-1">
                  <div
                    className="w-6 rounded-t bg-[var(--color-brand)]"
                    style={{ height: `${(m.booked / maxValue) * 100}%` }}
                    title={`Booked: $${m.booked.toLocaleString()}`}
                  />
                  <div
                    className="w-6 rounded-t bg-emerald-400 dark:bg-emerald-600"
                    style={{ height: `${(m.collected / maxValue) * 100}%` }}
                    title={`Collected: $${m.collected.toLocaleString()}`}
                  />
                </div>
                <p className="text-xs text-[var(--color-text-muted)]">{m.label}</p>
              </div>
            ))}
          </div>
          <div className="mt-4 flex items-center gap-4 text-xs text-[var(--color-text-muted)]">
            <span className="flex items-center gap-1.5">
              <span className="size-2.5 rounded-full bg-[var(--color-brand)]" /> Booked
            </span>
            <span className="flex items-center gap-1.5">
              <span className="size-2.5 rounded-full bg-emerald-400 dark:bg-emerald-600" /> Collected
            </span>
          </div>
        </div>
      )}
    </div>
  );
}
