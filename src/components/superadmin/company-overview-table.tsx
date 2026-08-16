import Link from "next/link";
import type { CompanyRow } from "@/lib/superadmin/platform-metrics";
import { CompanyActionsMenu } from "@/components/superadmin/company-actions-menu";

function money(cents: number): string {
  return cents > 0 ? `$${(cents / 100).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 0 })}` : "--";
}

const STATUS_STYLE: Record<string, string> = {
  active: "bg-emerald-500/10 text-emerald-400",
  trialing: "bg-blue-500/10 text-blue-400",
  past_due: "bg-red-500/10 text-red-400",
  paused: "bg-amber-500/10 text-amber-400", // "Suspended" in the console's language
  canceled: "bg-slate-500/10 text-slate-400",
  incomplete: "bg-amber-500/10 text-amber-400",
};
const STATUS_LABEL: Record<string, string> = {
  active: "Active",
  trialing: "Trial",
  past_due: "Past Due",
  paused: "Suspended",
  canceled: "Cancelled",
  incomplete: "Incomplete",
};

// Real per-company table -- built from the SAME companies array
// platform-metrics.ts already assembled with one join (no per-row query).
export function CompanyOverviewTable({ companies, usersByOrg }: { companies: CompanyRow[]; usersByOrg: Map<string, number> }) {
  return (
    <div className="overflow-x-auto rounded-xl border border-slate-800 bg-slate-900/60">
      <table className="w-full text-[13px]">
        <thead>
          <tr className="border-b border-slate-800 text-left text-[10.5px] font-semibold uppercase tracking-wide text-slate-500">
            <th className="px-4 py-2.5">Company</th>
            <th className="px-3 py-2.5">Plan</th>
            <th className="px-3 py-2.5">Status</th>
            <th className="px-3 py-2.5 text-right">MRR</th>
            <th className="px-3 py-2.5 text-right">Users</th>
            <th className="px-3 py-2.5">Signed Up</th>
            <th className="px-3 py-2.5 text-right">&nbsp;</th>
          </tr>
        </thead>
        <tbody>
          {companies.map((c) => (
            <tr key={c.id} className="border-b border-slate-800/70 last:border-0 hover:bg-slate-800/30">
              <td className="px-4 py-3">
                <Link href={`/admin/companies/${c.id}`} className="font-medium text-slate-100 hover:text-blue-400">
                  {c.name}
                </Link>
                <p className="text-[11px] text-slate-500">{c.slug}</p>
              </td>
              <td className="px-3 py-3 text-slate-300">{c.planName ?? "No plan"}</td>
              <td className="px-3 py-3">
                <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-medium ${STATUS_STYLE[c.status ?? ""] ?? "bg-slate-500/10 text-slate-400"}`}>
                  {c.status ? STATUS_LABEL[c.status] ?? c.status : "No subscription"}
                </span>
              </td>
              <td className="px-3 py-3 text-right font-medium text-purple-400">{money(c.mrrCents)}</td>
              <td className="px-3 py-3 text-right text-slate-300">{usersByOrg.get(c.id) ?? 0}</td>
              <td className="px-3 py-3 text-slate-500">{new Date(c.createdAt).toLocaleDateString()}</td>
              <td className="px-3 py-3 text-right">
                <CompanyActionsMenu orgId={c.id} companyName={c.name} planId={c.planId} status={c.status} />
              </td>
            </tr>
          ))}
          {companies.length === 0 && (
            <tr>
              <td colSpan={7} className="px-4 py-8 text-center text-sm text-slate-500">
                No companies yet.
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}
