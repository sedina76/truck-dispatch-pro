import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { SystemStatusCard } from "@/components/superadmin/system-status-card";
import { CheckCircle2, AlertTriangle } from "lucide-react";

// System Health: this app has no infrastructure/uptime monitoring
// integration (no external status provider, no synthetic checks). Rather
// than fabricate one, this page reports the one real, honest signal
// available -- whether the platform-admin data queries this console
// depends on actually succeeded -- and states the limitation plainly.
export default async function SuperAdminSystemHealthPage() {
  const supabase = await createClient();

  const checks = await Promise.all([
    supabase.from("organizations").select("id", { count: "exact", head: true }).then((r) => ({ name: "organizations", ok: !r.error })),
    supabase.from("organization_subscriptions").select("id", { count: "exact", head: true }).then((r) => ({ name: "organization_subscriptions", ok: !r.error })),
    supabase.from("billing_records").select("id", { count: "exact", head: true }).then((r) => ({ name: "billing_records", ok: !r.error })),
    supabase.from("profiles").select("id", { count: "exact", head: true }).then((r) => ({ name: "profiles", ok: !r.error })),
    supabase.rpc("get_platform_operational_snapshot").maybeSingle().then((r) => ({ name: "get_platform_operational_snapshot() [needs 0045]", ok: !r.error })),
    supabase.from("activity_logs").select("id", { count: "exact", head: true }).then((r) => ({ name: "activity_logs cross-tenant read [needs 0045]", ok: !r.error && (r.count ?? 0) >= 0 })),
  ]);

  const [{ data: snapshot }, { count: activeUserCount }, { count: trialingCount }] = await Promise.all([
    supabase.rpc("get_platform_operational_snapshot").maybeSingle(),
    supabase.from("profiles").select("id", { count: "exact", head: true }).eq("is_active", true),
    supabase.from("organization_subscriptions").select("id", { count: "exact", head: true }).eq("status", "trialing"),
  ]);
  const snap = snapshot as { active_users: number; live_dispatches: number; open_invoices: number } | null;

  return (
    <div className="space-y-6">
      <PageHeader title="System Health" description="Real query-level health checks for the Platform Console's own data dependencies." />

      <div className="rounded-xl border border-amber-500/20 bg-amber-500/5 p-4 text-[13px] text-amber-300">
        This is a data-availability check, not infrastructure/uptime monitoring -- no external status provider or synthetic-check system is wired up in this application.
      </div>

      <div className="rounded-xl border border-slate-800 bg-slate-900/60 p-5">
        <p className="mb-3 text-sm font-semibold text-slate-100">Data Dependency Checks</p>
        <div className="space-y-2.5">
          {checks.map((c) => (
            <div key={c.name} className="flex items-center justify-between text-[13px]">
              <span className="font-mono text-slate-300">{c.name}</span>
              {c.ok ? (
                <span className="flex items-center gap-1.5 text-emerald-400"><CheckCircle2 className="size-4" /> Reachable</span>
              ) : (
                <span className="flex items-center gap-1.5 text-amber-400"><AlertTriangle className="size-4" /> Unavailable</span>
              )}
            </div>
          ))}
        </div>
      </div>

      <SystemStatusCard
        activeUsers={activeUserCount ?? null}
        liveDispatches={snap?.live_dispatches ?? null}
        openInvoices={snap?.open_invoices ?? null}
        trialingCompanies={trialingCount ?? 0}
        available={!!snap}
      />
    </div>
  );
}
