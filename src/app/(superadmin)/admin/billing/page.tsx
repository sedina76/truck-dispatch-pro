import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { PlatformMetricCard } from "@/components/superadmin/platform-metric-card";
import { DollarSign, CheckCircle2, Clock, XCircle } from "lucide-react";

function money(cents: number): string {
  return `$${(cents / 100).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

const STATUS_STYLE: Record<string, string> = {
  paid: "bg-emerald-500/10 text-emerald-400",
  open: "bg-blue-500/10 text-blue-400",
  void: "bg-slate-500/10 text-slate-400",
  uncollectible: "bg-red-500/10 text-red-400",
};

// Billing: cross-tenant billing_records (platform SaaS invoices to
// tenants -- distinct from freight `invoices`), readable via the existing
// billing_records_platform_admin_select policy (0016). Real data only;
// this table is currently sparse since Stripe isn't wired up yet.
export default async function SuperAdminBillingPage() {
  const supabase = await createClient();

  const [{ data: records }, { data: orgs }] = await Promise.all([
    supabase.from("billing_records").select("id, organization_id, amount_cents, status, paid_at, period_start, period_end, created_at").order("created_at", { ascending: false }).limit(100),
    supabase.from("organizations").select("id, name"),
  ]);
  const orgNameById = new Map((orgs ?? []).map((o) => [o.id, o.name]));

  const rows = records ?? [];
  const paidTotal = rows.filter((r) => r.status === "paid").reduce((sum, r) => sum + r.amount_cents, 0);
  const openTotal = rows.filter((r) => r.status === "open").reduce((sum, r) => sum + r.amount_cents, 0);
  const uncollectibleCount = rows.filter((r) => r.status === "uncollectible").length;

  return (
    <div className="space-y-6">
      <PageHeader title="Billing" description="Platform SaaS billing history across every tenant." />

      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <PlatformMetricCard label="Total Invoices" value={rows.length} icon={DollarSign} tone="blue" />
        <PlatformMetricCard label="Paid" value={money(paidTotal)} icon={CheckCircle2} tone="emerald" />
        <PlatformMetricCard label="Open" value={money(openTotal)} icon={Clock} tone="amber" />
        <PlatformMetricCard label="Uncollectible" value={uncollectibleCount} icon={XCircle} tone="red" />
      </div>

      <div className="overflow-x-auto rounded-xl border border-slate-800 bg-slate-900/60">
        <table className="w-full text-[13px]">
          <thead>
            <tr className="border-b border-slate-800 text-left text-[10.5px] font-semibold uppercase tracking-wide text-slate-500">
              <th className="px-4 py-2.5">Company</th>
              <th className="px-3 py-2.5">Period</th>
              <th className="px-3 py-2.5 text-right">Amount</th>
              <th className="px-3 py-2.5">Status</th>
              <th className="px-4 py-2.5">Paid</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id} className="border-b border-slate-800/70 last:border-0">
                <td className="px-4 py-2.5 font-medium text-slate-100">{orgNameById.get(r.organization_id) ?? "--"}</td>
                <td className="px-3 py-2.5 text-slate-400">
                  {r.period_start ? new Date(r.period_start).toLocaleDateString() : "--"}
                  {r.period_end ? ` - ${new Date(r.period_end).toLocaleDateString()}` : ""}
                </td>
                <td className="px-3 py-2.5 text-right font-medium text-purple-400">{money(r.amount_cents)}</td>
                <td className="px-3 py-2.5">
                  <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-medium ${STATUS_STYLE[r.status] ?? "bg-slate-500/10 text-slate-400"}`}>{r.status}</span>
                </td>
                <td className="px-4 py-2.5 text-slate-500">{r.paid_at ? new Date(r.paid_at).toLocaleDateString() : "--"}</td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={5} className="px-4 py-8 text-center text-sm text-slate-500">
                  No billing records yet -- Stripe billing sync isn&apos;t wired up on this instance.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
