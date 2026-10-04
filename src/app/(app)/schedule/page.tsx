import Link from "next/link";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { cn } from "@/lib/utils";
import { getCurrentOrgId } from "@/lib/actions/records";
import { isValidIanaTimezone } from "@/lib/timezone/iana";
import { resolveStopTimezone } from "@/lib/timezone/resolve";
import { isMidnightLocal, shortZoneLabel } from "@/lib/timezone/format";
import { dayKey, visibleDays, shiftDay, validDay, stopStatus, dueStatus, groupByDay, STATUS_LABEL, type CalendarItem, type CalendarStatus } from "@/lib/schedule/calendar";

// Schedule: pickups and deliveries by day or week, colored by how they're
// going (on time / at risk / late / done), plus maintenance due dates and
// compliance expirations. Days follow the organization's time zone; each
// appointment's time is shown in its stop's own zone.

const TONE: Record<CalendarStatus, string> = {
  done: "border-l-muted-foreground/50 bg-muted/60 text-muted-foreground",
  on_site: "border-l-success bg-success/10",
  late: "border-l-danger bg-danger/10",
  at_risk: "border-l-warning bg-warning/10",
  on_time: "border-l-success bg-success/5",
  scheduled: "border-l-primary bg-primary/5",
  not_dispatched: "border-l-warning bg-card border-dashed",
  due: "border-l-desktop-text-muted bg-desktop-muted/60",
  overdue: "border-l-danger bg-danger/5",
};
const KIND_LABEL: Record<CalendarItem["kind"], string> = { pickup: "Pickup", delivery: "Delivery", maintenance: "Maintenance", compliance: "Expires" };
const ITEM_LABEL: Record<string, string> = {
  cdl_expiry: "CDL",
  medical_card_expiry: "Medical card",
  insurance_expiry: "Insurance",
  registration_expiry: "Registration",
  authority_expiry: "Authority",
  annual_inspection: "Annual inspection",
  drug_test: "Drug test",
  ifta_renewal: "IFTA renewal",
  dot_inspection: "DOT inspection",
  twic_expiry: "TWIC",
  hazmat_expiry: "Hazmat",
  passport_expiry: "Passport",
  other: "Compliance item",
};

export default async function SchedulePage({ searchParams }: { searchParams: Promise<{ view?: string; date?: string }> }) {
  const sp = await searchParams;
  const supabase = await createClient();

  let tz = "America/Chicago";
  try {
    const orgId = await getCurrentOrgId();
    const { data: org } = await supabase.from("organizations").select("timezone").eq("id", orgId).maybeSingle();
    if (org?.timezone && isValidIanaTimezone(org.timezone)) tz = org.timezone;
  } catch {
    // keep the fallback
  }

  const now = Date.now();
  const today = dayKey(new Date(now).toISOString(), tz);
  const view: "week" | "day" = sp.view === "day" ? "day" : "week";
  const day = validDay(sp.date, today);
  const days = visibleDays(day, view);
  // fetch a day either side so every time zone's appointments land on the right day
  const fromIso = new Date(Date.parse(`${days[0]}T00:00:00Z`) - 36 * 3600 * 1000).toISOString();
  const toIso = new Date(Date.parse(`${days.at(-1)}T23:59:59Z`) + 36 * 3600 * 1000).toISOString();

  const [{ data: stopRows }, { data: maint }, { data: comp }] = await Promise.all([
    supabase
      .from("load_stops")
      .select("id, load_id, stop_type, facility_name, city, state, scheduled_at, scheduled_window_end, arrived_at, departed_at, timezone, loads!inner(id, load_number, status)")
      .gte("scheduled_at", fromIso)
      .lte("scheduled_at", toIso)
      .neq("loads.status", "cancelled")
      .order("scheduled_at"),
    supabase
      .from("maintenance_records")
      .select("id, service_type, next_service_due_date, status, trucks(unit_number), trailers(unit_number)")
      .gte("next_service_due_date", days[0])
      .lte("next_service_due_date", days.at(-1)!)
      .neq("status", "cancelled"),
    supabase
      .from("compliance_items")
      .select("id, entity_type, entity_id, item_type, expiry_date, status, resolved_at")
      .gte("expiry_date", days[0])
      .lte("expiry_date", days.at(-1)!)
      .is("resolved_at", null)
      .neq("status", "waived"),
  ]);

  type StopRow = {
    id: string;
    load_id: string;
    stop_type: "pickup" | "delivery";
    facility_name: string | null;
    city: string | null;
    state: string | null;
    scheduled_at: string;
    scheduled_window_end: string | null;
    arrived_at: string | null;
    departed_at: string | null;
    timezone: string | null;
    loads: { id: string; load_number: string; status: string } | null;
  };
  const stops = (stopRows ?? []) as unknown as StopRow[];
  const loadIds = Array.from(new Set(stops.map((s) => s.load_id)));

  const { data: dispatches } = loadIds.length
    ? await supabase.from("dispatches").select("id, load_id, status").in("load_id", loadIds).neq("status", "cancelled")
    : { data: [] as { id: string; load_id: string; status: string }[] };
  const dispatchByLoad = new Map((dispatches ?? []).map((d) => [d.load_id, d]));
  const dispatchIds = (dispatches ?? []).map((d) => d.id);
  const { data: routes } = dispatchIds.length
    ? await supabase.from("dispatch_route_intelligence").select("dispatch_id, target_stop_id, risk_status, updated_at").in("dispatch_id", dispatchIds)
    : { data: [] as { dispatch_id: string; target_stop_id: string | null; risk_status: string | null; updated_at: string }[] };
  const riskByStop = new Map<string, string | null>();
  for (const r of routes ?? []) if (r.target_stop_id) riskByStop.set(r.target_stop_id, r.risk_status);

  // compliance: name what expires (driver / truck / trailer / carrier)
  type CompRow = { id: string; entity_type: string; entity_id: string; item_type: string; expiry_date: string; status: string };
  const compRows = (comp ?? []) as CompRow[];
  const idsOf = (t: string) => compRows.filter((c) => c.entity_type === t).map((c) => c.entity_id);
  const [drv, trk, trl, car] = await Promise.all([
    idsOf("driver").length ? supabase.from("drivers").select("id, first_name, last_name").in("id", idsOf("driver")) : Promise.resolve({ data: [] }),
    idsOf("truck").length ? supabase.from("trucks").select("id, unit_number").in("id", idsOf("truck")) : Promise.resolve({ data: [] }),
    idsOf("trailer").length ? supabase.from("trailers").select("id, unit_number").in("id", idsOf("trailer")) : Promise.resolve({ data: [] }),
    idsOf("carrier").length ? supabase.from("carriers").select("id, legal_name").in("id", idsOf("carrier")) : Promise.resolve({ data: [] }),
  ]);
  const nameOf = new Map<string, string>([
    ...((drv.data ?? []) as { id: string; first_name: string; last_name: string }[]).map((d) => [d.id, `${d.first_name} ${d.last_name}`] as [string, string]),
    ...((trk.data ?? []) as { id: string; unit_number: string }[]).map((t) => [t.id, `Truck ${t.unit_number}`] as [string, string]),
    ...((trl.data ?? []) as { id: string; unit_number: string }[]).map((t) => [t.id, `Trailer ${t.unit_number}`] as [string, string]),
    ...((car.data ?? []) as { id: string; legal_name: string }[]).map((c) => [c.id, c.legal_name] as [string, string]),
  ]);
  const ENTITY_HREF: Record<string, string> = { driver: "/drivers", truck: "/trucks", trailer: "/trailers", carrier: "/carriers" };

  const items: CalendarItem[] = [];
  for (const s of stops) {
    if (!s.loads) continue;
    const stopTz = resolveStopTimezone(s.timezone, tz).timezone;
    const dateOnly = isMidnightLocal(s.scheduled_at, stopTz) && !s.scheduled_window_end;
    const d = dispatchByLoad.get(s.load_id);
    const t = (iso: string) => new Intl.DateTimeFormat("en-US", { timeZone: stopTz, hour: "numeric", minute: "2-digit" }).format(new Date(iso));
    items.push({
      id: s.id,
      kind: s.stop_type,
      day: dateOnly ? dayKey(s.scheduled_at, stopTz) : dayKey(s.scheduled_at, tz),
      at: dateOnly ? null : s.scheduled_at,
      allDay: dateOnly,
      timeLabel: dateOnly ? "No time set" : `${t(s.scheduled_at)}${s.scheduled_window_end ? `-${t(s.scheduled_window_end)}` : ""} ${shortZoneLabel(stopTz, s.scheduled_at)}`,
      title: `${s.loads.load_number} ${s.stop_type}`,
      subtitle: [s.facility_name, [s.city, s.state].filter(Boolean).join(", ")].filter(Boolean).join(" -- "),
      href: d ? `/dispatch/board?dispatch=${d.id}` : `/loads/${s.load_id}`,
      status: stopStatus({
        scheduledAt: s.scheduled_at,
        windowEnd: s.scheduled_window_end,
        arrivedAt: s.arrived_at,
        departedAt: s.departed_at,
        dispatched: !!d,
        routeRisk: riskByStop.get(s.id) ?? null,
        dateOnly,
        now,
        timeZone: stopTz,
      }),
    });
  }
  for (const m of (maint ?? []) as unknown as { id: string; service_type: string; next_service_due_date: string; trucks: { unit_number: string } | null; trailers: { unit_number: string } | null }[]) {
    items.push({
      id: `m-${m.id}`,
      kind: "maintenance",
      day: m.next_service_due_date,
      at: null,
      allDay: true,
      timeLabel: "",
      title: `${m.trucks ? `Truck ${m.trucks.unit_number}` : m.trailers ? `Trailer ${m.trailers.unit_number}` : "Equipment"} service due`,
      subtitle: m.service_type.replace(/_/g, " "),
      href: `/maintenance/${m.id}`,
      status: dueStatus(m.next_service_due_date, today),
    });
  }
  for (const c of compRows) {
    items.push({
      id: `c-${c.id}`,
      kind: "compliance",
      day: c.expiry_date,
      at: null,
      allDay: true,
      timeLabel: "",
      title: `${ITEM_LABEL[c.item_type] ?? c.item_type.replace(/_/g, " ")} expires`,
      subtitle: nameOf.get(c.entity_id) ?? c.entity_type,
      href: ENTITY_HREF[c.entity_type] ? `${ENTITY_HREF[c.entity_type]}/${c.entity_id}` : "/compliance",
      status: dueStatus(c.expiry_date, today),
    });
  }

  const byDay = groupByDay(items, days);
  const qs = (v: "week" | "day", d: string) => `/schedule?view=${v}&date=${d}`;
  const fmtDay = (d: string, opts: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat("en-US", { timeZone: "UTC", ...opts }).format(new Date(`${d}T12:00:00Z`));
  const range = view === "day" ? fmtDay(day, { weekday: "long", month: "long", day: "numeric", year: "numeric" }) : `${fmtDay(days[0], { month: "short", day: "numeric" })} - ${fmtDay(days[6], { month: "short", day: "numeric", year: "numeric" })}`;
  const counts = { late: items.filter((i) => i.status === "late").length, atRisk: items.filter((i) => i.status === "at_risk").length, notDispatched: items.filter((i) => i.status === "not_dispatched").length };

  return (
    <div className="space-y-4">
      <PageHeader title="Schedule" description="Pickups and deliveries by day, colored by how they're going, plus maintenance due dates and expiring credentials." />

      <div className="flex flex-wrap items-center gap-2" data-testid="schedule-toolbar">
        <div className="flex items-center gap-1">
          <Link href={qs(view, shiftDay(day, view, -1))} aria-label="Previous" className="rounded-sm border border-desktop-border bg-card p-1.5 hover:bg-muted">
            <ChevronLeft className="size-4" />
          </Link>
          <Link href={qs(view, today)} className="rounded-sm border border-desktop-border bg-card px-3 py-1 text-[13px] font-medium hover:bg-muted">
            Today
          </Link>
          <Link href={qs(view, shiftDay(day, view, 1))} aria-label="Next" className="rounded-sm border border-desktop-border bg-card p-1.5 hover:bg-muted">
            <ChevronRight className="size-4" />
          </Link>
        </div>
        <p className="text-sm font-semibold">{range}</p>
        <div className="ml-auto flex items-center gap-1 rounded-sm border border-desktop-border bg-card p-0.5 text-[12.5px]">
          <Link href={qs("day", day)} className={cn("rounded-sm px-2.5 py-1", view === "day" ? "bg-primary text-primary-foreground" : "hover:bg-muted")}>
            Day
          </Link>
          <Link href={qs("week", day)} className={cn("rounded-sm px-2.5 py-1", view === "week" ? "bg-primary text-primary-foreground" : "hover:bg-muted")}>
            Week
          </Link>
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-[11.5px] text-muted-foreground">
        {(["late", "at_risk", "on_time", "scheduled", "not_dispatched", "on_site", "done", "due", "overdue"] as CalendarStatus[]).map((s) => (
          <span key={s} className="flex items-center gap-1">
            <span className={cn("inline-block h-3 w-1.5 rounded-sm border-l-4", TONE[s])} /> {STATUS_LABEL[s]}
          </span>
        ))}
        {(counts.late > 0 || counts.atRisk > 0 || counts.notDispatched > 0) && (
          <span className="ml-auto font-medium text-desktop-text">
            {[counts.late && `${counts.late} late`, counts.atRisk && `${counts.atRisk} at risk`, counts.notDispatched && `${counts.notDispatched} not dispatched`].filter(Boolean).join(" · ")} in this view
          </span>
        )}
      </div>

      <div className={cn("grid gap-2", view === "week" ? "grid-cols-1 md:grid-cols-7" : "grid-cols-1")} data-testid="schedule-grid">
        {days.map((d) => {
          const list = byDay.get(d) ?? [];
          const isToday = d === today;
          return (
            <section key={d} className={cn("min-h-[120px] rounded-md border bg-card", isToday ? "border-primary" : "border-desktop-border")}>
              <header className={cn("flex items-baseline justify-between border-b px-2 py-1.5", isToday ? "border-primary/40 bg-primary/5" : "border-desktop-border")}>
                <Link href={qs("day", d)} className="text-[12.5px] font-semibold hover:underline">
                  {fmtDay(d, { weekday: "short" })} <span className="font-normal text-muted-foreground">{fmtDay(d, { month: "short", day: "numeric" })}</span>
                </Link>
                {list.length > 0 && <span className="text-[11px] text-muted-foreground">{list.length}</span>}
              </header>
              <ul className="space-y-1.5 p-1.5">
                {list.length === 0 && <li className="px-1 py-2 text-[11.5px] text-muted-foreground">Nothing scheduled</li>}
                {list.map((it) => (
                  <li key={it.id}>
                    <Link href={it.href} className={cn("block rounded-sm border border-l-4 border-desktop-border px-2 py-1 text-[12px] hover:shadow-sm", TONE[it.status])} title={`${KIND_LABEL[it.kind]} · ${STATUS_LABEL[it.status]}`}>
                      <p className="flex items-center justify-between gap-1">
                        <span className="truncate font-semibold">{it.title}</span>
                        <span className="shrink-0 text-[10.5px] font-medium uppercase tracking-wide opacity-80">{STATUS_LABEL[it.status]}</span>
                      </p>
                      {it.timeLabel && <p className="tabular-nums opacity-90">{it.timeLabel}</p>}
                      {it.subtitle && <p className={cn("truncate opacity-80", view === "day" && "whitespace-normal")}>{it.subtitle}</p>}
                    </Link>
                  </li>
                ))}
              </ul>
            </section>
          );
        })}
      </div>
    </div>
  );
}
