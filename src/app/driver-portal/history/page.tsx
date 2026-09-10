import Link from "next/link";
import { redirect } from "next/navigation";
import { History } from "lucide-react";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { StatusBadge } from "@/components/ui/status-badge";
import { getLatestDocumentsByEntity } from "@/lib/documents/latest-document";
import { computePodStatus } from "@/lib/documents/pod-status";

// Trip History (spec section 18): completed dispatches assigned to THIS
// driver only. No rate/margin/invoice fields selected anywhere in this
// query -- there is no code path here that could print them.
export default async function DriverPortalHistoryPage() {
  const identity = await getDriverPortalSession();
  if (!identity) redirect("/driver-portal/login");

  const supabase = createServiceRoleClient();
  const { data: dispatches } = await supabase
    .from("dispatches")
    .select("id, status, dispatched_at, completed_at, loads:loads!dispatches_load_id_fkey(id, load_number, total_miles)")
    .eq("driver_id", identity.driverId)
    .in("status", ["delivered", "completed"])
    .order("dispatched_at", { ascending: false })
    .limit(100);

  const rows = (dispatches ?? []) as unknown as {
    id: string;
    status: string;
    dispatched_at: string;
    completed_at: string | null;
    loads: { id: string; load_number: string; total_miles: number | null } | null;
  }[];

  const loadIds = rows.map((r) => r.loads?.id).filter((v): v is string => !!v);
  const [podByLoad, stopsByLoad] = await Promise.all([
    getLatestDocumentsByEntity(supabase, "load", "pod", loadIds),
    loadIds.length
      ? supabase.from("load_stops").select("load_id, stop_type, stop_sequence, city, state, scheduled_at").in("load_id", loadIds)
      : Promise.resolve({ data: [] }),
  ]);
  const stopsData = (stopsByLoad as { data: { load_id: string; stop_type: string; stop_sequence: number; city: string | null; state: string | null; scheduled_at: string | null }[] | null }).data ?? [];

  return (
    <div className="flex flex-1 flex-col gap-4">
      <h1 className="flex items-center gap-2 text-lg font-semibold tracking-tight">
        <History className="size-4.5 text-primary" /> Trip History
      </h1>

      {rows.length === 0 ? (
        <div className="rounded-2xl border border-border bg-card p-4">
          <p className="text-sm text-muted-foreground">No completed trips yet.</p>
        </div>
      ) : (
        <div className="space-y-2.5">
          {rows.map((d) => {
            const loadId = d.loads?.id;
            const pickup = stopsData.find((s) => s.load_id === loadId && s.stop_type === "pickup");
            const delivery = stopsData.filter((s) => s.load_id === loadId && s.stop_type === "delivery").slice(-1)[0];
            const podStatus = computePodStatus(loadId ? podByLoad.get(loadId) : null);
            return (
              <Link key={d.id} href={`/driver-portal/history/${d.id}`} className="block rounded-2xl border border-border bg-card p-4">
                <div className="flex items-center justify-between">
                  <p className="text-sm font-semibold">{d.loads?.load_number ?? "Load"}</p>
                  <StatusBadge status={d.status} />
                </div>
                <p className="mt-1 truncate text-xs text-muted-foreground">
                  {pickup ? `${pickup.city ?? "--"}, ${pickup.state ?? "--"}` : "--"} &rarr; {delivery ? `${delivery.city ?? "--"}, ${delivery.state ?? "--"}` : "--"}
                </p>
                <div className="mt-2 flex items-center justify-between text-xs">
                  <span className="text-muted-foreground">{d.loads?.total_miles ? `${d.loads.total_miles} mi` : "--"}</span>
                  <span className="flex items-center gap-1.5">
                    POD: <StatusBadge status={podStatus} />
                  </span>
                </div>
              </Link>
            );
          })}
        </div>
      )}
    </div>
  );
}
