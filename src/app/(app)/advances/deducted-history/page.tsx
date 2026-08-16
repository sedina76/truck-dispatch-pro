import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { KpiRow, KpiCard } from "@/components/ui/kpi-card";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBarChart, type StatusPoint } from "@/components/dashboard/status-bar-chart";

export default async function DeductedHistoryPage() {
  const supabase = await createClient();

  const { data } = await supabase
    .from("dispatch_advances")
    .select("amount, expense_type, updated_at")
    .eq("status", "deducted")
    .order("updated_at", { ascending: false });

  const deducted = data ?? [];
  const total = deducted.reduce((sum, a) => sum + Number(a.amount), 0);

  const months: { key: string; label: string; total: number }[] = [];
  for (let i = 5; i >= 0; i--) {
    const d = new Date();
    d.setDate(1);
    d.setMonth(d.getMonth() - i);
    months.push({ key: `${d.getFullYear()}-${d.getMonth()}`, label: d.toLocaleString("en-US", { month: "short" }), total: 0 });
  }
  for (const row of deducted) {
    const d = new Date(row.updated_at);
    const month = months.find((m) => m.key === `${d.getFullYear()}-${d.getMonth()}`);
    if (month) month.total += Number(row.amount);
  }

  const byType = new Map<string, number>();
  for (const row of deducted) {
    byType.set(row.expense_type, (byType.get(row.expense_type) ?? 0) + Number(row.amount));
  }
  const typeColors: Record<string, string> = {
    fuel: "#2f5be0",
    lumper: "#5b4fe0",
    toll: "#0ea472",
    parking: "#d68a04",
    scale: "#38bdf8",
    repair: "#dc3545",
    driver_advance: "#818cf8",
    hotel: "#94a3b8",
    other: "#64748b",
  };
  const typeData: StatusPoint[] = Array.from(byType.entries())
    .map(([type, amount]) => ({ status: type.replace(/_/g, " "), count: amount, color: typeColors[type] ?? "#94a3b8" }))
    .sort((a, b) => b.count - a.count);

  return (
    <div className="space-y-6">
      <PageHeader title="Deducted History" description="Advances recouped through settlement or invoice deductions, by month." />

      <KpiRow>
        <KpiCard label="Total Deducted (all time)" value={`$${total.toLocaleString()}`} />
        <KpiCard label="Deducted Records" value={deducted.length} />
        <KpiCard label="This Month" value={`$${(months[months.length - 1]?.total ?? 0).toLocaleString()}`} />
      </KpiRow>

      {deducted.length === 0 ? (
        <EmptyState title="Nothing deducted yet" description="Once advances are deducted from settlements or invoices, monthly totals will appear here." />
      ) : (
        <div className="grid grid-cols-1 gap-5 lg:grid-cols-2">
          <Card>
            <CardHeader>
              <CardTitle>Deducted by Month</CardTitle>
              <CardDescription>Last 6 months</CardDescription>
            </CardHeader>
            <CardContent>
              <div className="flex h-56 items-end gap-4 px-2">
                {months.map((m) => {
                  const max = Math.max(1, ...months.map((mm) => mm.total));
                  return (
                    <div key={m.key} className="flex flex-1 flex-col items-center gap-2">
                      <span className="text-xs font-medium text-muted-foreground">
                        {m.total > 0 ? `$${(m.total / 1000).toFixed(1)}k` : ""}
                      </span>
                      <div className="flex w-full flex-1 items-end">
                        <div
                          className="w-full rounded-t bg-primary"
                          style={{ height: `${(m.total / max) * 100}%`, minHeight: m.total > 0 ? 4 : 0 }}
                        />
                      </div>
                      <span className="text-xs text-muted-foreground">{m.label}</span>
                    </div>
                  );
                })}
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Deducted by Expense Type</CardTitle>
              <CardDescription>All-time breakdown</CardDescription>
            </CardHeader>
            <CardContent>
              <StatusBarChart data={typeData} />
            </CardContent>
          </Card>
        </div>
      )}
    </div>
  );
}
