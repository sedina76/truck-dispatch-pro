import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";

function money(cents: number): string {
  return `$${(cents / 100).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

const STATUS_STYLE: Record<string, string> = {
  active: "bg-emerald-500/10 text-emerald-400",
  trialing: "bg-blue-500/10 text-blue-400",
  past_due: "bg-red-500/10 text-red-400",
  paused: "bg-amber-500/10 text-amber-400",
  canceled: "bg-slate-500/10 text-slate-400",
  incomplete: "bg-amber-500/10 text-amber-400",
};

// Subscriptions: the global plan catalog (subscription_plans -- "writable
// only by service_role" per its own schema comment, so this is
// deliberately read-only here, not a plan editor) plus every tenant's
// current subscription, linking into the existing per-company "Manage
// Subscription" form (/admin/companies/[id]) -- the one real place plan/
// status changes already happen. No second subscription-management system.
export default async function SuperAdminSubscriptionsPage() {
  const supabase = await createClient();

  const [{ data: plans }, { data: orgs }, { data: subs }] = await Promise.all([
    supabase.from("subscription_plans").select("id, name, tier, monthly_price_cents, annual_price_cents, max_users, max_trucks, max_active_loads, is_active").order("monthly_price_cents"),
    supabase.from("organizations").select("id, name, slug").order("name"),
    supabase.from("organization_subscriptions").select("organization_id, status, plan_id, subscription_plans(name)"),
  ]);

  type SubRow = { organization_id: string; status: string; subscription_plans: { name: string } | null };
  const subByOrg = new Map(((subs ?? []) as unknown as SubRow[]).map((s) => [s.organization_id, s]));

  return (
    <div className="space-y-6">
      <PageHeader title="Subscriptions" description="Global plan catalog and every tenant's current subscription." />

      <div>
        <p className="mb-3 text-sm font-semibold text-slate-100">Plan Catalog</p>
        <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
          {(plans ?? []).map((p) => (
            <div key={p.id} className="rounded-xl border border-slate-800 bg-slate-900/60 p-4">
              <p className="text-sm font-semibold text-slate-100">{p.name}</p>
              <p className="mt-1 text-2xl font-semibold text-purple-400">{money(p.monthly_price_cents)}<span className="text-xs font-normal text-slate-500">/mo</span></p>
              {p.annual_price_cents != null && <p className="text-[11px] text-slate-500">{money(p.annual_price_cents)}/yr</p>}
              <div className="mt-3 space-y-1 text-[11.5px] text-slate-400">
                <p>{p.max_users ?? "Unlimited"} users</p>
                <p>{p.max_trucks ?? "Unlimited"} trucks</p>
                <p>{p.max_active_loads ?? "Unlimited"} active loads</p>
              </div>
              {!p.is_active && <p className="mt-2 text-[10.5px] font-medium uppercase tracking-wide text-slate-600">Inactive plan</p>}
            </div>
          ))}
        </div>
      </div>

      <div>
        <p className="mb-3 text-sm font-semibold text-slate-100">Tenant Subscriptions</p>
        <div className="overflow-x-auto rounded-xl border border-slate-800 bg-slate-900/60">
          <table className="w-full text-[13px]">
            <thead>
              <tr className="border-b border-slate-800 text-left text-[10.5px] font-semibold uppercase tracking-wide text-slate-500">
                <th className="px-4 py-2.5">Company</th>
                <th className="px-3 py-2.5">Plan</th>
                <th className="px-3 py-2.5">Status</th>
                <th className="px-4 py-2.5 text-right">Manage</th>
              </tr>
            </thead>
            <tbody>
              {(orgs ?? []).map((org) => {
                const sub = subByOrg.get(org.id);
                return (
                  <tr key={org.id} className="border-b border-slate-800/70 last:border-0">
                    <td className="px-4 py-2.5 font-medium text-slate-100">{org.name}</td>
                    <td className="px-3 py-2.5 text-slate-300">{sub?.subscription_plans?.name ?? "No plan"}</td>
                    <td className="px-3 py-2.5">
                      <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-medium ${STATUS_STYLE[sub?.status ?? ""] ?? "bg-slate-500/10 text-slate-400"}`}>
                        {sub?.status ? sub.status.replace(/_/g, " ") : "No subscription"}
                      </span>
                    </td>
                    <td className="px-4 py-2.5 text-right">
                      <Link href={`/admin/companies/${org.id}`} className="text-[11px] font-medium text-blue-400 hover:text-blue-300">
                        Manage &rarr;
                      </Link>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
