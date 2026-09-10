"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import {
  DndContext,
  DragOverlay,
  PointerSensor,
  useSensor,
  useSensors,
  useDroppable,
  type DragEndEvent,
  type DragStartEvent,
} from "@dnd-kit/core";
import { useDraggable } from "@dnd-kit/core";
import { CSS } from "@dnd-kit/utilities";
import { Truck, UserRound, Search, X, AlertTriangle, MessageCircle } from "lucide-react";
import { cn } from "@/lib/utils";
import { updateDispatchBoardStatus } from "../board-actions";
import { useToast } from "@/components/ui/toast";
import { DispatchDrawer } from "@/components/dispatch/dispatch-drawer";
import { formatStopDateTime } from "@/lib/timezone/format";

export type DispatchCard = {
  id: string;
  status: string;
  load_number: string;
  carrier_name: string;
  truck_unit: string;
  driver_name: string;
  // null for driver/viewer (Phase 2G.11) -- financial data is not merely
  // hidden in JSX, it's never fetched for those roles in the first place
  // (see dispatch/board/page.tsx).
  net_amount: number | null;
  pickup_city: string | null;
  pickup_state: string | null;
  delivery_city: string | null;
  delivery_state: string | null;
  pickup_time: string | null;
  pickup_timezone: string;
  exceptions: string[];
  // Phase 2C (spec section 22/23) -- null when route intelligence hasn't
  // calculated yet or migration 0060 isn't applied; "unknown" once a row
  // exists but couldn't classify a risk (e.g. no appointment set).
  eta_at: string | null;
  eta_timezone: string;
  miles_remaining_meters: number | null;
  risk_status: "unknown" | "on_time" | "at_risk" | "late" | "arrived" | null;
  // Phase 2D (spec section 56) -- independent of risk_status, never
  // conflated with it.
  off_route: boolean;
  // Phase 2E (spec section 32) -- count of ACTIVE (non-resolved)
  // operational_exceptions episodes for this dispatch. Always 0 (never
  // undefined/error) when migration 0063 isn't applied yet -- see
  // dispatch/board/page.tsx's graceful-degrade fetch.
  active_exception_count: number;
  // Phase 2I.1A section F -- count of dispatch_messages rows for this
  // dispatch with sender_type='driver' AND read_at IS NULL. Deliberately
  // NOT derived from `notifications` (dispatch_messages.read_at stays the
  // sole source of truth); clears once the Communication panel is opened
  // and markDispatchMessagesRead() succeeds, visible on the next
  // refresh/poll.
  unread_driver_message_count: number;
};

// A booked load that has NO active dispatch yet -- shown in the read-only
// "Booked / Unassigned" column (never draggable: there is no dispatch row
// to update). Clicking one starts a New Dispatch prefilled with that load.
export type BookedLoadCard = { load_id: string; load_number: string };

// Exact mapping approved for this pass -- dispatch_status itself is
// unchanged; these are only which existing enum values a column visually
// buckets, and which single value a drop into that column writes.
const COLUMNS: { key: string; title: string; statuses: string[]; dropStatus: string }[] = [
  { key: "assigned", title: "Assigned", statuses: ["assigned", "accepted"], dropStatus: "assigned" },
  { key: "en_route_to_pickup", title: "En Route to Pickup", statuses: ["en_route_to_pickup"], dropStatus: "en_route_to_pickup" },
  { key: "at_pickup", title: "At Pickup", statuses: ["at_pickup"], dropStatus: "at_pickup" },
  { key: "loaded", title: "Loaded", statuses: ["loaded"], dropStatus: "loaded" },
  { key: "in_transit", title: "In Transit", statuses: ["en_route_to_delivery"], dropStatus: "en_route_to_delivery" },
  { key: "at_delivery", title: "At Delivery", statuses: ["at_delivery"], dropStatus: "at_delivery" },
  { key: "delivered", title: "Delivered", statuses: ["delivered", "completed"], dropStatus: "delivered" },
  { key: "cancelled", title: "Cancelled", statuses: ["cancelled"], dropStatus: "cancelled" },
];

const EXCEPTION_TONE: Record<string, string> = {
  "POD Missing": "bg-warning/15 text-warning",
  "Late Pickup": "bg-danger/15 text-danger",
  "Late Delivery": "bg-danger/15 text-danger",
  Detention: "bg-danger/15 text-danger",
  "AT RISK": "bg-warning/15 text-warning",
  "OFF ROUTE": "bg-danger/15 text-danger",
};
// Dynamic exceptions (spec section 22): "Detention in Xm" and "Xm LATE"
// carry a number, so they can't be exact object keys -- matched by suffix
// instead. A late load's badge must read unmistakably more urgent than an
// at-risk one (spec: "prioritize exception visibility"). "OFF ROUTE · 1.3
// mi" (Phase 2D) matched by prefix for the same reason.
function exceptionTone(ex: string): string {
  if (EXCEPTION_TONE[ex]) return EXCEPTION_TONE[ex];
  if (ex.endsWith("LATE")) return "bg-danger/15 text-danger";
  if (ex.startsWith("Detention in")) return "bg-warning/15 text-warning";
  if (ex.startsWith("OFF ROUTE")) return "bg-danger/15 text-danger";
  return "bg-muted text-muted-foreground";
}

const ACTIVE_STATUSES = new Set(["assigned", "accepted", "en_route_to_pickup", "at_pickup", "loaded", "en_route_to_delivery", "at_delivery"]);

function DispatchDraggableCard({ card, onOpen }: { card: DispatchCard; onOpen: (id: string) => void }) {
  const { attributes, listeners, setNodeRef, transform, isDragging } = useDraggable({ id: card.id });
  const route = card.pickup_city || card.delivery_city ? `${card.pickup_city ?? "--"}${card.pickup_state ? `, ${card.pickup_state}` : ""} → ${card.delivery_city ?? "--"}${card.delivery_state ? `, ${card.delivery_state}` : ""}` : null;
  const showRouteIntel = ACTIVE_STATUSES.has(card.status) && card.status !== "assigned" && (card.eta_at || card.miles_remaining_meters != null);

  return (
    <div
      ref={setNodeRef}
      {...listeners}
      {...attributes}
      onClick={() => onOpen(card.id)}
      style={{ transform: CSS.Translate.toString(transform) }}
      className={cn(
        "cursor-pointer touch-none rounded-lg border border-border bg-card p-3 shadow-elevation-1 transition-shadow active:cursor-grabbing",
        isDragging && "opacity-40"
      )}
    >
      <div className="flex items-center justify-between">
        <span className="flex items-center gap-1.5 text-sm font-semibold">
          {card.load_number}
          {card.active_exception_count > 0 && (
            // Compact indicator (spec section 32) -- links to the
            // Exception Center rather than opening the Drawer, so it needs
            // its own click handler that stops the card's own onOpen.
            <Link
              href={`/dispatch/exceptions?q=${encodeURIComponent(card.load_number)}`}
              onClick={(e) => e.stopPropagation()}
              title={`${card.active_exception_count} active exception${card.active_exception_count === 1 ? "" : "s"}`}
              className="inline-flex items-center gap-0.5 rounded-sm bg-danger/15 px-1 py-0.5 text-[10px] font-bold text-danger hover:bg-danger/25"
            >
              <AlertTriangle className="size-2.5" />
              {card.active_exception_count}
            </Link>
          )}
        </span>
        {card.net_amount != null && <span className="text-sm font-medium text-success">${card.net_amount.toLocaleString()}</span>}
      </div>
      <p className="mt-1 truncate text-xs text-muted-foreground">{card.carrier_name}</p>
      <div className="mt-2 flex items-center gap-3 text-xs text-muted-foreground">
        <span className="flex items-center gap-1">
          <Truck className="size-3.5" />
          {card.truck_unit}
        </span>
        <span className="flex items-center gap-1">
          <UserRound className="size-3.5" />
          {card.driver_name}
        </span>
      </div>
      {route && <p className="mt-1.5 truncate text-[11px] text-muted-foreground">{route}</p>}
      {card.pickup_time && (
        <p className="text-[11px] text-muted-foreground">
          Pickup: {formatStopDateTime(card.pickup_time, card.pickup_timezone, { dateOnly: false })}
        </p>
      )}
      {showRouteIntel && (
        <p className="mt-1 text-[11px] font-medium text-muted-foreground">
          {card.eta_at && `ETA ${formatStopDateTime(card.eta_at, card.eta_timezone, { timeOnly: true })}`}
          {card.eta_at && card.miles_remaining_meters != null && " · "}
          {card.miles_remaining_meters != null && `${Math.round(card.miles_remaining_meters / 1609.344)} mi`}
        </p>
      )}
      {(card.exceptions.length > 0 || card.unread_driver_message_count > 0) && (
        <div className="mt-1.5 flex flex-wrap gap-1">
          {card.exceptions.map((ex) => (
            <span key={ex} className={cn("inline-flex items-center gap-1 rounded-sm px-1.5 py-0.5 text-[10px] font-semibold", exceptionTone(ex))}>
              <AlertTriangle className="size-2.5" />
              {ex}
            </span>
          ))}
          {card.unread_driver_message_count > 0 && (
            // Deliberately non-dominant tone (spec section F) -- an unread
            // message is informational, not an operational exception, so
            // it must never compete visually with the red/amber exception
            // badges above.
            <span className="inline-flex items-center gap-1 rounded-sm bg-primary/10 px-1.5 py-0.5 text-[10px] font-semibold text-primary">
              <MessageCircle className="size-2.5" />
              Messages • {card.unread_driver_message_count}
            </span>
          )}
        </div>
      )}
    </div>
  );
}

function KanbanColumn({ column, cards, onOpen }: { column: (typeof COLUMNS)[number]; cards: DispatchCard[]; onOpen: (id: string) => void }) {
  const { setNodeRef, isOver } = useDroppable({ id: column.key });

  return (
    <div className="w-72 shrink-0">
      <div className="sticky top-0 z-10 mb-2 flex items-center justify-between bg-background px-1 py-1">
        <p className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">{column.title}</p>
        <span className="rounded-full bg-muted px-2 py-0.5 text-[11px] font-medium text-muted-foreground">{cards.length}</span>
      </div>
      <div
        ref={setNodeRef}
        className={cn(
          "flex min-h-[200px] flex-col gap-2 rounded-xl border border-dashed border-transparent p-1.5 transition-colors",
          isOver && "border-primary/40 bg-primary/5"
        )}
      >
        {cards.map((card) => (
          <DispatchDraggableCard key={card.id} card={card} onOpen={onOpen} />
        ))}
        {cards.length === 0 && (
          <div className="rounded-xl border border-dashed border-border p-5 text-center text-xs text-muted-foreground">Drop dispatches here</div>
        )}
      </div>
    </div>
  );
}

type RiskFilter = "" | "at_risk" | "late" | "unknown";
// Phase 2D (spec section 31/56): a SEPARATE boolean, not a value inside
// RiskFilter -- route deviation and schedule risk are independent
// dimensions and must be independently filterable/combinable, never
// conflated into one mutually-exclusive selector.
type Filters = { search: string; driver: string; truck: string; carrier: string; risk: RiskFilter; offRoute: boolean };
const EMPTY_FILTERS: Filters = { search: "", driver: "", truck: "", carrier: "", risk: "", offRoute: false };

function FilterBar({ cards, filters, onChange }: { cards: DispatchCard[]; filters: Filters; onChange: (f: Filters) => void }) {
  const drivers = useMemo(() => [...new Set(cards.map((c) => c.driver_name))].filter((v) => v !== "--").sort(), [cards]);
  const trucks = useMemo(() => [...new Set(cards.map((c) => c.truck_unit))].filter((v) => v !== "--").sort(), [cards]);
  const carriers = useMemo(() => [...new Set(cards.map((c) => c.carrier_name))].filter((v) => v !== "--").sort(), [cards]);
  const hasFilters = filters.search || filters.driver || filters.truck || filters.carrier || filters.risk || filters.offRoute;

  return (
    <div className="flex flex-wrap items-center gap-2 rounded-lg border border-desktop-border bg-desktop-panel px-2.5 py-2">
      <div className="relative flex-1 min-w-[200px]">
        <Search className="pointer-events-none absolute left-2 top-1/2 size-3.5 -translate-y-1/2 text-muted-foreground" />
        <input
          value={filters.search}
          onChange={(e) => onChange({ ...filters, search: e.target.value })}
          placeholder="Search load #, driver, truck, carrier, city..."
          className="h-7 w-full rounded-sm border border-desktop-border bg-desktop-panel pl-7 pr-2 text-[12.5px] outline-none focus-visible:border-primary"
        />
      </div>
      <select value={filters.driver} onChange={(e) => onChange({ ...filters, driver: e.target.value })} className="h-7 rounded-sm border border-desktop-border bg-desktop-panel px-2 text-[12.5px]">
        <option value="">All Drivers</option>
        {drivers.map((d) => (
          <option key={d} value={d}>{d}</option>
        ))}
      </select>
      <select value={filters.truck} onChange={(e) => onChange({ ...filters, truck: e.target.value })} className="h-7 rounded-sm border border-desktop-border bg-desktop-panel px-2 text-[12.5px]">
        <option value="">All Trucks</option>
        {trucks.map((t) => (
          <option key={t} value={t}>{t}</option>
        ))}
      </select>
      <select value={filters.carrier} onChange={(e) => onChange({ ...filters, carrier: e.target.value })} className="h-7 rounded-sm border border-desktop-border bg-desktop-panel px-2 text-[12.5px]">
        <option value="">All Carriers</option>
        {carriers.map((c) => (
          <option key={c} value={c}>{c}</option>
        ))}
      </select>
      {hasFilters && (
        <button type="button" onClick={() => onChange(EMPTY_FILTERS)} className="inline-flex h-7 items-center gap-1 rounded-sm border border-desktop-border px-2 text-[12px] font-medium hover:bg-desktop-muted">
          <X className="size-3.5" /> Clear Filters
        </button>
      )}
    </div>
  );
}

// Spec section 23: an exception summary/filter row rather than more
// permanent KPI cards (the board's KPI strip is already Total/Active/
// Delivered/Carrier Net) -- clicking a count filters the board to exactly
// those cards, click again to clear. On Time isn't included as a clickable
// exception filter (it's the non-exceptional majority state), just shown
// for context.
function RiskSummaryBar({ cards, filters, onChange }: { cards: DispatchCard[]; filters: Filters; onChange: (f: Filters) => void }) {
  const activeCards = cards.filter((c) => !["delivered", "completed", "cancelled"].includes(c.status));
  const onTime = activeCards.filter((c) => c.risk_status === "on_time").length;
  const atRisk = activeCards.filter((c) => c.risk_status === "at_risk").length;
  const late = activeCards.filter((c) => c.risk_status === "late").length;
  const unknown = activeCards.filter((c) => c.risk_status == null || c.risk_status === "unknown").length;
  const offRoute = activeCards.filter((c) => c.off_route).length;

  function toggle(risk: RiskFilter) {
    onChange({ ...filters, risk: filters.risk === risk ? "" : risk });
  }

  return (
    <div className="flex flex-wrap items-center gap-1.5 text-[12px]">
      <span className="rounded-sm border border-desktop-success/30 bg-desktop-success/10 px-2 py-1 font-medium text-desktop-success">On Time {onTime}</span>
      <button type="button" onClick={() => toggle("at_risk")} className={cn("rounded-sm border px-2 py-1 font-medium", filters.risk === "at_risk" ? "border-warning bg-warning/20 text-warning" : "border-warning/30 bg-warning/10 text-warning hover:bg-warning/20")}>
        At Risk {atRisk}
      </button>
      <button type="button" onClick={() => toggle("late")} className={cn("rounded-sm border px-2 py-1 font-medium", filters.risk === "late" ? "border-danger bg-danger/20 text-danger" : "border-danger/30 bg-danger/10 text-danger hover:bg-danger/20")}>
        Late {late}
      </button>
      <button type="button" onClick={() => toggle("unknown")} className={cn("rounded-sm border px-2 py-1 font-medium", filters.risk === "unknown" ? "border-desktop-border bg-desktop-muted text-desktop-text" : "border-desktop-border bg-desktop-muted/50 text-muted-foreground hover:bg-desktop-muted")}>
        ETA Unknown {unknown}
      </button>
      {(offRoute > 0 || filters.offRoute) && (
        <button
          type="button"
          onClick={() => onChange({ ...filters, offRoute: !filters.offRoute })}
          className={cn("rounded-sm border px-2 py-1 font-medium", filters.offRoute ? "border-danger bg-danger/20 text-danger" : "border-danger/30 bg-danger/10 text-danger hover:bg-danger/20")}
        >
          Off Route {offRoute}
        </button>
      )}
    </div>
  );
}

// Read-only leftmost column: booked loads with no active dispatch. No
// droppable, no draggable cards -- assignment happens on the New Dispatch
// page, so each card is a link there.
function BookedColumn({ loads }: { loads: BookedLoadCard[] }) {
  return (
    <div className="w-72 shrink-0">
      <div className="sticky top-0 z-10 mb-2 flex items-center justify-between bg-background px-1 py-1">
        <p className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">Booked / Unassigned</p>
        <span className="rounded-full bg-muted px-2 py-0.5 text-[11px] font-medium text-muted-foreground">{loads.length}</span>
      </div>
      <div className="flex min-h-[120px] flex-col gap-2 rounded-lg bg-muted/40 p-2">
        {loads.map((l) => (
          <Link
            key={l.load_id}
            href={`/dispatch/new?load_id=${l.load_id}`}
            className="rounded-lg border border-dashed border-border bg-card p-3 text-sm font-semibold shadow-elevation-1 transition-shadow hover:shadow-elevation-2"
          >
            {l.load_number}
            <span className="mt-1 block text-xs font-normal text-muted-foreground">Booked · not yet assigned</span>
          </Link>
        ))}
        {loads.length === 0 && <p className="px-1 py-2 text-[11px] text-muted-foreground">No unassigned booked loads.</p>}
      </div>
    </div>
  );
}

export function KanbanBoard({ initialCards, bookedLoads = [] }: { initialCards: DispatchCard[]; bookedLoads?: BookedLoadCard[] }) {
  const [cards, setCards] = useState(initialCards);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [openDispatchId, setOpenDispatchId] = useState<string | null>(null);
  const [filters, setFilters] = useState<Filters>(EMPTY_FILTERS);
  const toast = useToast();
  const searchParams = useSearchParams();

  // Phase 2I.1A section E: a notification bell click for a dispatch_message
  // notification lands here as /dispatch/board?dispatch=<id> -- open that
  // dispatch's drawer once on arrival. Guarded by a ref (not a dependency
  // on the param itself) so it fires exactly once per navigation rather
  // than re-opening a manually-closed drawer if some other state update
  // re-runs this effect.
  const appliedDispatchParamRef = useRef(false);
  useEffect(() => {
    if (appliedDispatchParamRef.current) return;
    const target = searchParams.get("dispatch");
    if (target) {
      appliedDispatchParamRef.current = true;
      setOpenDispatchId(target);
    }
  }, [searchParams]);
  // Suppresses the drawer-open click that would otherwise fire right after
  // a real drag-and-drop (dnd-kit's PointerSensor activation-distance
  // gate stops a genuine drag from firing native onClick in most browsers,
  // but this is a cheap, explicit belt-and-suspenders guard rather than
  // relying on that alone).
  const suppressClickRef = useRef(false);

  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 6 } }));

  function onDragStart(event: DragStartEvent) {
    setActiveId(String(event.active.id));
    suppressClickRef.current = true;
  }

  function onDragEnd(event: DragEndEvent) {
    setActiveId(null);
    setTimeout(() => {
      suppressClickRef.current = false;
    }, 50);

    const { active, over } = event;
    if (!over) return;

    const targetColumn = COLUMNS.find((c) => c.key === over.id);
    if (!targetColumn) return;

    const card = cards.find((c) => c.id === active.id);
    if (!card || targetColumn.statuses.includes(card.status)) return;

    const previousStatus = card.status;
    const newStatus = targetColumn.dropStatus;

    // 1. Move immediately (optimistic).
    setCards((prev) => prev.map((c) => (c.id === card.id ? { ...c, status: newStatus } : c)));

    // 2. Persist; 3/4. keep-or-rollback + toast.
    updateDispatchBoardStatus(card.id, newStatus).then((result) => {
      if (result.ok) {
        toast.show("success", `${card.load_number} moved to ${targetColumn.title}.`);
      } else {
        setCards((prev) => prev.map((c) => (c.id === card.id ? { ...c, status: previousStatus } : c)));
        toast.show("error", result.error);
      }
    });
  }

  const filteredCards = useMemo(() => {
    const q = filters.search.trim().toLowerCase();
    return cards.filter((c) => {
      if (filters.driver && c.driver_name !== filters.driver) return false;
      if (filters.truck && c.truck_unit !== filters.truck) return false;
      if (filters.carrier && c.carrier_name !== filters.carrier) return false;
      if (filters.risk) {
        const cardRisk = c.risk_status ?? "unknown";
        if (filters.risk === "unknown" ? cardRisk !== "unknown" : cardRisk !== filters.risk) return false;
      }
      if (filters.offRoute && !c.off_route) return false;
      if (!q) return true;
      return [c.load_number, c.driver_name, c.truck_unit, c.carrier_name, c.pickup_city, c.delivery_city]
        .filter(Boolean)
        .some((v) => v!.toLowerCase().includes(q));
    });
  }, [cards, filters]);

  const activeCard = activeId ? cards.find((c) => c.id === activeId) : null;

  function handleOpen(id: string) {
    if (suppressClickRef.current) return;
    setOpenDispatchId(id);
  }

  return (
    <div className="space-y-3">
      <FilterBar cards={cards} filters={filters} onChange={setFilters} />
      <RiskSummaryBar cards={cards} filters={filters} onChange={setFilters} />
      {/* Explicit, stable id (SSR hydration fix): with no id prop,
          @dnd-kit's DndContext derives its aria-describedby value
          (DndDescribedBy-N) from a MODULE-LEVEL counter (useUniqueId(),
          @dnd-kit/utilities) that is NOT request-scoped -- confirmed by
          reading that function's own source (`let ids = {}` at module
          scope, incremented on every call with no id/value argument). A
          long-lived server process's counter keeps climbing across
          unrelated requests/renders (so a given SSR pass can easily land
          on "-1", "-2", etc.), while a fresh browser page load always
          starts its own copy of that same module at "-0" -- a mismatch
          that exists independently of this board's own code and would
          reproduce on ANY DndContext with no explicit id, on any server
          that has handled more than one request. Passing a fixed id here
          makes useUniqueId() return it immediately (see its own
          `if (value) return value` short-circuit) -- byte-identical
          between server and client on every render, regardless of how
          many times this component (or any other DndContext elsewhere)
          has mounted before. This is the library's own documented
          escape hatch -- not a manual aria-describedby override. */}
      <DndContext id="dispatch-board-dnd" sensors={sensors} onDragStart={onDragStart} onDragEnd={onDragEnd}>
        <div className="flex gap-4 overflow-x-auto pb-2">
          <BookedColumn loads={bookedLoads} />
          {COLUMNS.map((column) => (
            <KanbanColumn key={column.key} column={column} cards={filteredCards.filter((c) => column.statuses.includes(c.status))} onOpen={handleOpen} />
          ))}
        </div>
        <DragOverlay>{activeCard ? <DispatchDraggableCard card={activeCard} onOpen={() => {}} /> : null}</DragOverlay>
      </DndContext>

      <DispatchDrawer dispatchId={openDispatchId} onClose={() => setOpenDispatchId(null)} />
    </div>
  );
}
