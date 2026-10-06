import Link from "next/link";
import { Download, AlertTriangle, Building2, CheckCircle2, Lock, Gift, Clock, DollarSign } from "lucide-react";
import type { PlatformReport } from "@/lib/superadmin/platform-reports";
import { ATTENTION_LABEL } from "@/lib/superadmin/report-rows";
import { ACCESS_STYLE } from "@/lib/superadmin/company-access";
import { PlatformMetricCard } from "@/components/superadmin/platform-metric-card";

// Platform Console -> Reports, presentation only (data: getPlatformReport()).

function money(cents: number): string {
  return `$${(cents / 100).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

function when(iso: string | null): string {
  if (!iso) return "Never";
  const days = Math.floor((Date.now() - new Date(iso).getTime()) / 86_400_000);
  if (days <= 0) return "Today";
  if (days === 1) return "Yesterday";
  if (days < 30) return `${days} days ago`;
  return new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

function Bars({ items, format }: { items: { label: string; value: number }[]; format: (n: number) => string }) {
  const max = Math.max(1, ...items.map((i) => i.value));
  return (
    <div className="flex h-40 items-end gap-1.5">
      {items.map((i) => (
        <div key={i.label} className="flex h-full min-w-0 flex-1 flex-col items-center gap-1.5" title={`${i.label}: ${format(i.value)}`}>
          <span className="h-4 text-[10.5px] font-medium text-slate-400">{i.value > 0 ? format(i.value) : ""}</span>
          {/* Bar area has a definite height so the percentage below is real. */}
          <div className="relative w-full flex-1">
            <div
              className="absolute inset-x-0 bottom-0 rounded-t bg-blue-500/80"
              style={{ height: `${i.value > 0 ? Math.max(4, (i.value / max) * 100) : 1}%`, opacity: i.value > 0 ? 1 : 0.25 }}
            />
          </div>
          <span className="truncate text-[10px] text-slate-500">{i.label}</span>
        </div>
      ))}
    </div>
  );
}

export function ReportsView({ report }: { report: PlatformReport }) {
  const { rows } = report;

  const count = (k: string) => rows.filter((r) => r.accessKey === k).length;
  const canUse = rows.filter((r) => !["locked", "suspended"].includes(r.accessKey)).length;
  const attention = rows.filter((r) => r.attention.length > 0);
  const revenueTotal = report.revenueByMonth.reduce((s, m) => s + m.totalCents, 0);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-xl font-semibold tracking-tight text-slate-50">Reports</h1>
          <p className="mt-1 text-sm text-slate-400">Who can use the TMS, who needs attention, and how the platform is growing.</p>
        </div>
        <a
          href="/admin/reports/export"
          className="flex h-9 items-center gap-1.5 rounded-lg border border-slate-700 px-3 text-[12.5px] font-medium text-slate-200 hover:bg-slate-800"
        >
          <Download className="size-3.5" /> Download CSV
        </a>
      </div>

      <div className="grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-6">
        <PlatformMetricCard label="Companies" value={rows.length} icon={Building2} tone="blue" />
        <PlatformMetricCard label="Can use the app" value={canUse} icon={CheckCircle2} tone="emerald" />
        <PlatformMetricCard label="Locked out" value={count("locked")} icon={Lock} tone={count("locked") > 0 ? "red" : "neutral"} />
        <PlatformMetricCard label="Free access" value={count("free")} icon={Gift} tone="blue" />
        <PlatformMetricCard label="On trial" value={count("trial")} icon={Clock} tone="purple" />
        <PlatformMetricCard label="Paying" value={count("paying") + count("grace")} icon={DollarSign} tone="emerald" />
      </div>

      <section aria-labelledby="attention-title" className="rounded-xl border border-slate-800 bg-slate-900/60">
        <div className="flex items-center gap-2 border-b border-slate-800 px-5 py-3.5">
          <AlertTriangle className="size-4 text-amber-400" />
          <h2 id="attention-title" className="text-sm font-semibold text-slate-100">Needs attention</h2>
          <span className="text-[12px] text-slate-500">{attention.length} {attention.length === 1 ? "company" : "companies"}</span>
        </div>
        {attention.length === 0 ? (
          <p className="px-5 py-6 text-sm text-slate-500">Nothing needs attention right now.</p>
        ) : (
          <ul className="divide-y divide-slate-800">
            {attention.map((r) => (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-3 px-5 py-3">
                <div className="min-w-0">
                  <Link href={`/admin/companies/${r.id}?tab=subscription`} className="text-[13px] font-medium text-slate-100 hover:text-blue-400">
                    {r.name}
                  </Link>
                  <p className="text-[12px] text-slate-500">{r.ownerEmail ?? "No owner email"}</p>
                </div>
                <div className="flex flex-wrap gap-1.5">
                  {r.attention.map((a) => (
                    <span
                      key={a}
                      className={`rounded-full px-2 py-0.5 text-[11px] font-medium ${a === "locked" || a === "suspended" || a === "past_due" ? "bg-red-500/10 text-red-400" : "bg-amber-500/10 text-amber-300"}`}
                    >
                      {ATTENTION_LABEL[a]}
                    </span>
                  ))}
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section aria-labelledby="access-title">
        <div className="mb-3 flex items-baseline justify-between gap-3">
          <h2 id="access-title" className="text-sm font-semibold text-slate-100">Company access</h2>
          {!report.signInsAvailable && <p className="text-[11.5px] text-amber-400">Last sign-in times are unavailable right now.</p>}
        </div>
        <div className="overflow-x-auto rounded-xl border border-slate-800 bg-slate-900/60">
          <table className="w-full text-[13px]">
            <thead>
              <tr className="border-b border-slate-800 text-left text-[10.5px] font-semibold uppercase tracking-wide text-slate-500">
                <th className="px-4 py-2.5">Company</th>
                <th className="px-3 py-2.5">Access</th>
                <th className="px-3 py-2.5">Plan</th>
                <th className="px-3 py-2.5">Owner</th>
                <th className="px-3 py-2.5 text-right">Users</th>
                <th className="px-3 py-2.5">Last sign-in</th>
                <th className="px-3 py-2.5">Signed up</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id} className="border-b border-slate-800/70 last:border-0 hover:bg-slate-800/30">
                  <td className="px-4 py-2.5">
                    <Link href={`/admin/companies/${r.id}`} className="font-medium text-slate-100 hover:text-blue-400">
                      {r.name}
                    </Link>
                  </td>
                  <td className="px-3 py-2.5">
                    <span title={r.accessDetail} className={`inline-flex items-center whitespace-nowrap rounded-full px-2 py-0.5 text-[11px] font-medium ${ACCESS_STYLE[r.accessKey]}`}>
                      {r.accessLabel}
                    </span>
                  </td>
                  <td className="px-3 py-2.5 text-slate-300">{r.planName ?? "No plan"}</td>
                  <td className="px-3 py-2.5 text-slate-400">{r.ownerEmail ?? "--"}</td>
                  <td className="px-3 py-2.5 text-right text-slate-300">{r.userCount}</td>
                  <td className={`px-3 py-2.5 ${r.lastSignInAt ? "text-slate-300" : "text-amber-400"}`}>{when(r.lastSignInAt)}</td>
                  <td className="px-3 py-2.5 text-slate-500">{new Date(r.createdAt).toLocaleDateString()}</td>
                </tr>
              ))}
              {rows.length === 0 && (
                <tr>
                  <td colSpan={7} className="px-4 py-8 text-center text-sm text-slate-500">No companies yet.</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <div className="grid grid-cols-1 gap-3 xl:grid-cols-2">
        <section aria-labelledby="signups-title" className="rounded-xl border border-slate-800 bg-slate-900/60 p-5">
          <h2 id="signups-title" className="text-sm font-semibold text-slate-100">New companies by month</h2>
          <p className="mb-4 mt-1 text-[12px] text-slate-500">Last 12 months · {report.signupsByMonth.reduce((s, m) => s + m.count, 0)} total</p>
          <Bars items={report.signupsByMonth.map((m) => ({ label: m.label, value: m.count }))} format={(n) => String(n)} />
        </section>
        <section aria-labelledby="revenue-title" className="rounded-xl border border-slate-800 bg-slate-900/60 p-5">
          <h2 id="revenue-title" className="text-sm font-semibold text-slate-100">Money collected by month</h2>
          <p className="mb-4 mt-1 text-[12px] text-slate-500">
            Paid billing records, last 12 months · {money(revenueTotal)} total
          </p>
          {!report.revenueAvailable ? (
            <p className="text-sm text-slate-500">Billing records are unavailable right now.</p>
          ) : revenueTotal === 0 ? (
            <p className="text-sm text-slate-500">No payments recorded yet. Payments appear here once Stripe billing is connected and customers pay.</p>
          ) : (
            <Bars items={report.revenueByMonth.map((m) => ({ label: m.label, value: m.totalCents }))} format={(n) => `$${Math.round(n / 100).toLocaleString("en-US")}`} />
          )}
        </section>
      </div>
    </div>
  );
}
