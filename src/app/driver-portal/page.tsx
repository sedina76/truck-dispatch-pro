import { redirect } from "next/navigation";
import Link from "next/link";
import { Package, Wallet, FileText, Receipt, History, ArrowRight, UserRound } from "lucide-react";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { getDashboardData } from "@/lib/driver-portal/dashboard-data";
import { StatusBadge } from "@/components/ui/status-badge";
import { LocationSharing } from "@/components/driver-portal/location-sharing";
import { LogoutButton } from "@/components/driver-portal/logout-button";
import { formatStopDateTime } from "@/lib/timezone/format";

// Mobile-first dashboard (spec sections 1-3). Every counter comes from
// getDashboardData()'s small fixed set of real queries -- never fabricated.
export default async function DriverPortalHomePage() {
  const identity = await getDriverPortalSession();
  if (!identity) redirect("/driver-portal/login");

  const { dispatch, stops, counters } = await getDashboardData(identity);
  const pickup = stops.find((s) => s.stop_type === "pickup");
  const delivery = stops.filter((s) => s.stop_type === "delivery").slice(-1)[0];

  return (
    <div className="flex flex-1 flex-col gap-4">
      <div className="flex items-center justify-between">
        <div>
          <p className="text-sm text-muted-foreground">Welcome back,</p>
          <h1 className="text-xl font-semibold tracking-tight">{identity.firstName} {identity.lastName}</h1>
          <p className="mt-0.5 text-xs font-medium text-muted-foreground">
            {counters.hasActiveTrip ? "Active Trip" : "No Active Dispatch"}
          </p>
        </div>
        <div className="flex items-center gap-1.5">
          <Link href="/driver-portal/profile" className="flex size-9 items-center justify-center rounded-full border border-border text-muted-foreground">
            <UserRound className="size-4" />
          </Link>
          <LogoutButton />
        </div>
      </div>

      <div className="grid grid-cols-2 gap-2.5">
        <CounterTile label="Active Trip" value={counters.hasActiveTrip ? 1 : 0} tone={counters.hasActiveTrip ? "primary" : "neutral"} />
        <CounterTile label="Documents Needed" value={counters.documentsNeeded} tone={counters.documentsNeeded > 0 ? "warning" : "neutral"} />
        <CounterTile label="Pending Expenses" value={counters.pendingExpenses} tone={counters.pendingExpenses > 0 ? "info" : "neutral"} />
        <CounterTile label="Unpaid Settlements" value={counters.unpaidSettlements} tone={counters.unpaidSettlements > 0 ? "warning" : "neutral"} />
      </div>

      {dispatch ? (
        <div className="rounded-2xl border border-primary/30 bg-card p-4 shadow-sm">
          <div className="mb-3 flex items-center justify-between">
            <p className="flex items-center gap-1.5 text-base font-semibold">
              <Package className="size-4 text-primary" /> {dispatch.load_number}
            </p>
            <StatusBadge status={dispatch.status} />
          </div>

          {(pickup || delivery) && (
            <div className="mb-3 flex items-center gap-2 text-sm">
              <span className="min-w-0 flex-1 truncate font-medium">{pickup ? `${pickup.city ?? "--"}, ${pickup.state ?? "--"}` : "--"}</span>
              <ArrowRight className="size-4 shrink-0 text-muted-foreground" />
              <span className="min-w-0 flex-1 truncate text-right font-medium">{delivery ? `${delivery.city ?? "--"}, ${delivery.state ?? "--"}` : "--"}</span>
            </div>
          )}

          <div className="grid grid-cols-2 gap-y-2 text-sm">
            <Field label="Pickup" value={pickup ? formatStopDateTime(pickup.scheduled_at, pickup.timezone) : "--"} />
            <Field label="Delivery" value={delivery ? formatStopDateTime(delivery.scheduled_at, delivery.timezone) : "--"} />
            <Field label="Truck" value={dispatch.truck_unit ?? "--"} />
            <Field label="Trailer" value={dispatch.trailer_unit ?? "--"} />
          </div>

          <div className="mt-4 flex flex-wrap gap-2">
            <Link href="/driver-portal/trip" className="flex h-11 flex-1 items-center justify-center rounded-xl bg-primary px-3 text-sm font-semibold text-primary-foreground">
              View Trip
            </Link>
            <Link href="/driver-portal/trip#status" className="flex h-11 flex-1 items-center justify-center rounded-xl border border-border bg-card px-3 text-sm font-medium">
              Update Status
            </Link>
            <Link href="/driver-portal/documents" className="flex h-11 flex-1 items-center justify-center rounded-xl border border-border bg-card px-3 text-sm font-medium">
              Upload Document
            </Link>
          </div>
        </div>
      ) : (
        <div className="rounded-2xl border border-border bg-card p-4">
          <div className="mb-1 flex items-center gap-2">
            <Package className="size-4 text-muted-foreground" />
            <p className="text-sm font-medium">Current Trip</p>
          </div>
          <p className="text-sm text-muted-foreground">No active dispatch right now.</p>
          <div className="mt-3 grid grid-cols-2 gap-2">
            <QuickLink href="/driver-portal/history" icon={History} label="Trip History" />
            <QuickLink href="/driver-portal/settlements" icon={Wallet} label="Settlements" />
            <QuickLink href="/driver-portal/expenses" icon={Receipt} label="Expenses" />
            <QuickLink href="/driver-portal/documents" icon={FileText} label="Documents" />
          </div>
        </div>
      )}

      <LocationSharing currentLoadNumber={dispatch?.load_number ?? null} />
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

const TILE_TONE: Record<string, string> = {
  neutral: "text-foreground",
  primary: "text-primary",
  warning: "text-warning",
  info: "text-secondary",
};

function CounterTile({ label, value, tone }: { label: string; value: number; tone: keyof typeof TILE_TONE }) {
  return (
    <div className="rounded-2xl border border-border bg-card p-3.5">
      <p className={`text-2xl font-bold leading-none ${TILE_TONE[tone]}`}>{value}</p>
      <p className="mt-1 text-[11px] font-medium text-muted-foreground">{label}</p>
    </div>
  );
}

function QuickLink({ href, icon: Icon, label }: { href: string; icon: typeof Wallet; label: string }) {
  return (
    <Link href={href} className="flex h-11 items-center gap-2 rounded-xl border border-border px-3 text-sm font-medium">
      <Icon className="size-4 text-primary" />
      {label}
    </Link>
  );
}
