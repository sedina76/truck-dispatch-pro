import Link from "next/link";
import { redirect, notFound } from "next/navigation";
import { ArrowLeft, MapPin, FileText, Receipt, Wallet } from "lucide-react";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { StatusBadge } from "@/components/ui/status-badge";
import { getLatestDocument } from "@/lib/documents/latest-document";
import { computePodStatus } from "@/lib/documents/pod-status";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

// .eq("driver_id", identity.driverId) on the dispatch lookup is the real
// access control -- another driver's dispatch id resolves to notFound(),
// never their trip/document/expense/settlement data (spec section 32).
export default async function DriverPortalHistoryDetailPage({ params }: { params: Promise<{ dispatchId: string }> }) {
  const { dispatchId } = await params;
  const identity = await getDriverPortalSession();
  if (!identity) redirect("/driver-portal/login");

  const supabase = createServiceRoleClient();
  const { data: dispatch } = await supabase
    .from("dispatches")
    .select("id, status, dispatched_at, completed_at, trucks(unit_number), trailers(unit_number), loads(id, load_number, commodity, total_miles)")
    .eq("id", dispatchId)
    .eq("driver_id", identity.driverId)
    .maybeSingle();
  if (!dispatch) notFound();

  const d = dispatch as unknown as {
    id: string;
    status: string;
    trucks: { unit_number: string } | null;
    trailers: { unit_number: string } | null;
    loads: { id: string; load_number: string; commodity: string | null; total_miles: number | null } | null;
  };
  const loadId = d.loads?.id;

  const [{ data: stops }, pod, { data: docs }, { data: expenses }, { data: settlementItems }] = await Promise.all([
    loadId ? supabase.from("load_stops").select("stop_type, stop_sequence, city, state, scheduled_at").eq("load_id", loadId).order("stop_sequence") : Promise.resolve({ data: [] }),
    loadId ? getLatestDocument(supabase, "load", loadId, "pod") : Promise.resolve(null),
    loadId ? supabase.from("documents").select("id, document_type, file_name, created_at").eq("entity_type", "load").eq("entity_id", loadId).order("created_at", { ascending: false }) : Promise.resolve({ data: [] }),
    loadId ? supabase.from("expenses").select("id, category, total_amount, status").eq("load_id", loadId).eq("driver_id", identity.driverId) : Promise.resolve({ data: [] }),
    d.loads?.load_number
      ? supabase
          .from("driver_settlement_items")
          .select("driver_settlement_id, gross_pay, driver_settlements!inner(settlement_number, status, driver_id)")
          .eq("load_number", d.loads.load_number)
          .eq("driver_settlements.driver_id", identity.driverId)
      : Promise.resolve({ data: [] }),
  ]);
  const podStatus = computePodStatus(pod);

  return (
    <div className="flex flex-1 flex-col gap-4">
      <div className="flex items-center gap-2">
        <Link href="/driver-portal/history" className="text-muted-foreground"><ArrowLeft className="size-4" /></Link>
        <h1 className="text-lg font-semibold tracking-tight">{d.loads?.load_number ?? "Trip"}</h1>
        <StatusBadge status={d.status} />
      </div>

      <div className="rounded-2xl border border-border bg-card p-4">
        <div className="grid grid-cols-2 gap-y-2 text-sm">
          <Field label="Truck" value={d.trucks?.unit_number ?? "--"} />
          <Field label="Trailer" value={d.trailers?.unit_number ?? "--"} />
          <Field label="Commodity" value={d.loads?.commodity ?? "--"} />
          <Field label="Miles" value={d.loads?.total_miles != null ? String(d.loads.total_miles) : "--"} />
        </div>
      </div>

      <div className="rounded-2xl border border-border bg-card p-4">
        <p className="mb-2 flex items-center gap-1.5 text-xs font-medium uppercase tracking-wide text-muted-foreground">
          <MapPin className="size-3.5" /> Stops
        </p>
        {(stops ?? []).map((s, i) => (
          <p key={i} className="text-sm capitalize">
            {s.stop_sequence}. {s.stop_type}: {s.city ?? "--"}, {s.state ?? "--"}
          </p>
        ))}
      </div>

      <div className="rounded-2xl border border-border bg-card p-4">
        <p className="mb-2 flex items-center justify-between text-xs font-medium uppercase tracking-wide text-muted-foreground">
          <span className="flex items-center gap-1.5"><FileText className="size-3.5" /> Documents</span>
          <StatusBadge status={podStatus} />
        </p>
        {(docs ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">No documents uploaded.</p>
        ) : (
          (docs ?? []).map((doc) => (
            <p key={doc.id} className="truncate text-sm capitalize text-muted-foreground">{doc.document_type.replace(/_/g, " ")}: {doc.file_name}</p>
          ))
        )}
      </div>

      {(expenses ?? []).length > 0 && (
        <div className="rounded-2xl border border-border bg-card p-4">
          <p className="mb-2 flex items-center gap-1.5 text-xs font-medium uppercase tracking-wide text-muted-foreground">
            <Receipt className="size-3.5" /> Expenses
          </p>
          {(expenses ?? []).map((e) => (
            <div key={e.id} className="flex items-center justify-between text-sm">
              <span className="capitalize">{e.category.replace(/_/g, " ")}</span>
              <span className="flex items-center gap-2">
                {money(e.total_amount)} <StatusBadge status={e.status} />
              </span>
            </div>
          ))}
        </div>
      )}

      {(settlementItems ?? []).length > 0 && (
        <div className="rounded-2xl border border-border bg-card p-4">
          <p className="mb-2 flex items-center gap-1.5 text-xs font-medium uppercase tracking-wide text-muted-foreground">
            <Wallet className="size-3.5" /> Settlement
          </p>
          {(settlementItems as unknown as { driver_settlement_id: string; gross_pay: number; driver_settlements: { settlement_number: string; status: string } }[]).map((item) => (
            <Link key={item.driver_settlement_id} href={`/driver-portal/settlements/${item.driver_settlement_id}`} className="flex items-center justify-between text-sm text-primary">
              <span>{item.driver_settlements.settlement_number}</span>
              <span>{money(item.gross_pay)}</span>
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-[10.5px] font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className="font-medium">{value}</p>
    </div>
  );
}
