import { Users, Truck, FileWarning, HeartPulse, Hourglass } from "lucide-react";

// "Right Now" operational panel. Active Users/Live Dispatches/Open
// Invoices come from get_platform_operational_snapshot() (0045) -- a
// narrow, count-only, platform-admin-gated RPC, never raw cross-tenant
// rows. Trial Companies reuses totals.trialingCount, already computed by
// getPlatformOverview() from organization_subscriptions for the KPI row
// and breakdown donut -- no new query. System Health here is deliberately
// minimal and honest: this app has no infrastructure-monitoring/uptime
// data source, so rather than invent a fake "All Systems Operational"
// indicator, it reports the one real signal available -- whether this
// page's own data queries succeeded -- and says so plainly.
export function SystemStatusCard({
  activeUsers,
  liveDispatches,
  openInvoices,
  trialingCompanies,
  available,
}: {
  activeUsers: number | null;
  liveDispatches: number | null;
  openInvoices: number | null;
  trialingCompanies: number;
  available: boolean;
}) {
  return (
    <div className="rounded-xl border border-slate-800 bg-slate-900/60 p-4">
      <p className="mb-3 text-sm font-semibold text-slate-100">Right Now</p>
      <div className="space-y-3">
        <Row icon={Users} label="Active Users" value={activeUsers} tone="text-blue-400" />
        <Row icon={Truck} label="Live Dispatches" value={liveDispatches} tone="text-emerald-400" />
        <Row icon={FileWarning} label="Open Invoices" value={openInvoices} tone="text-amber-400" />
        <Row icon={Hourglass} label="Trial Companies" value={trialingCompanies} tone="text-purple-400" />
        <div className="flex items-center justify-between border-t border-slate-800 pt-3">
          <span className="flex items-center gap-2 text-[12.5px] text-slate-300">
            <HeartPulse className="size-4 text-emerald-400" /> System Health
          </span>
          <span className={`text-[11px] font-medium ${available ? "text-emerald-400" : "text-slate-500"}`}>
            {available ? "Data queries responding" : "Some metrics unavailable"}
          </span>
        </div>
      </div>
      {!available && (
        <p className="mt-3 text-[11px] text-slate-600">
          Live Dispatches/Open Invoices require RUN_THIS_FOR_PLATFORM_CONSOLE_REDESIGN.sql.
        </p>
      )}
    </div>
  );
}

function Row({ icon: Icon, label, value, tone }: { icon: typeof Users; label: string; value: number | null; tone: string }) {
  return (
    <div className="flex items-center justify-between">
      <span className="flex items-center gap-2 text-[12.5px] text-slate-300">
        <Icon className={`size-4 ${tone}`} /> {label}
      </span>
      <span className="text-sm font-semibold text-slate-100 tabular-nums">{value ?? "Unavailable"}</span>
    </div>
  );
}
