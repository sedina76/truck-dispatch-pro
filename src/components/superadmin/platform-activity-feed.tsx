import { Building2, CreditCard, ShieldCheck, Activity } from "lucide-react";
import type { ActivityEntry } from "@/lib/superadmin/platform-metrics";

const ICON: Record<ActivityEntry["kind"], typeof Building2> = {
  company_created: Building2,
  subscription_status: Activity,
  payment_received: CreditCard,
  admin_action: ShieldCheck,
};
const TONE: Record<ActivityEntry["kind"], string> = {
  company_created: "bg-blue-500/10 text-blue-400",
  subscription_status: "bg-purple-500/10 text-purple-400",
  payment_received: "bg-emerald-500/10 text-emerald-400",
  admin_action: "bg-amber-500/10 text-amber-400",
};

function timeAgo(iso: string): string {
  const diffMs = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(diffMs / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}

// Every entry is a real row from organizations/organization_subscriptions/
// billing_records/activity_logs -- see platform-metrics.ts. No fabricated
// activity is ever synthesized here.
export function PlatformActivityFeed({ entries }: { entries: ActivityEntry[] }) {
  return (
    <div className="rounded-xl border border-slate-800 bg-slate-900/60 p-5">
      <p className="mb-4 text-sm font-semibold text-slate-100">Recent Platform Activity</p>
      {entries.length === 0 ? (
        <p className="text-sm text-slate-500">No platform activity recorded yet.</p>
      ) : (
        <div className="space-y-3.5">
          {entries.map((e) => {
            const Icon = ICON[e.kind];
            return (
              <div key={e.id} className="flex items-start gap-2.5">
                <div className={`flex size-6 shrink-0 items-center justify-center rounded-md ${TONE[e.kind]}`}>
                  <Icon className="size-3.5" />
                </div>
                <div className="min-w-0 flex-1">
                  <p className="truncate text-[12.5px] font-medium text-slate-200">{e.title}</p>
                  <p className="truncate text-[11px] text-slate-500">{e.detail}</p>
                </div>
                <span className="shrink-0 text-[10.5px] text-slate-600">{timeAgo(e.occurredAt)}</span>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
