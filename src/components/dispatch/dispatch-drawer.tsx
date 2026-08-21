"use client";

import { useEffect, useState, useTransition } from "react";
import Link from "next/link";
import {
  X,
  ChevronsLeftRight,
  Phone,
  MessageSquare,
  FileText,
  Printer,
  StickyNote,
  MoreHorizontal,
  Loader2,
  MapPin,
  Radio,
  Satellite,
  AlertTriangle,
} from "lucide-react";
import { StatusBadge } from "@/components/ui/status-badge";
import { Button } from "@/components/ui/button";
import { DesktopCollapsibleSection, CollapsibleSectionsProvider, CollapsibleSectionsToolbar } from "@/components/desktop/collapsible-section";
import { CommunicationPanel } from "@/components/dispatch/communication-panel";
import { DocumentsPanel } from "@/components/dispatch/documents-panel";
import { DropdownMenu, DropdownMenuTrigger, DropdownMenuContent, DropdownMenuItem } from "@/components/ui/dropdown-menu";
import { useToast } from "@/components/ui/toast";
import {
  getDispatchDrawerData,
  addDispatchQuickNote,
  updateDispatchBoardStatus,
  setStopCoordinates,
  setStopAppointment,
  setStopTimezone,
  dismissRouteDeviation,
  type DispatchDrawerData,
  type StopGeofenceInfo,
} from "@/app/(app)/dispatch/board-actions";
import { refreshDispatchEta } from "@/app/(app)/dispatch/route-actions";
import { formatMinutes } from "@/lib/dispatch/detention";
import { formatMiles, formatLateLabel, formatMarginLabel } from "@/lib/routing/risk";
import { formatStopDateTime, formatStopWindow, stopLocalDateInputValue, stopLocalTimeInputValue } from "@/lib/timezone/format";
import { COMMON_TIMEZONES } from "@/lib/timezone/iana";
import { cn } from "@/lib/utils";

// Phase 2I.1: 'documents' and 'communication' default OPEN (unlike every
// other secondary section) -- both are now primary operational surfaces
// the toolbar's Call/Message/Documents buttons scroll straight to (same
// #drawer-documents anchor mechanic that already existed, extended to a
// second #drawer-communication anchor). Always-open means the toolbar
// only ever needs to scroll, never to also force a collapsed section
// open -- DesktopCollapsibleSection has no imperative "open" API to call
// from outside its own provider tree, and inventing one would be a wider,
// riskier change to a component several other pages already share.
const SECTION_DEFAULTS: Record<string, boolean> = {
  overview: true,
  driver_equipment: true,
  communication: true,
  pickup: true,
  delivery: false,
  tracking: false,
  documents: true,
  activity: false,
};

const STATUS_LABEL: Record<string, string> = {
  assigned: "Assigned",
  accepted: "Assigned",
  en_route_to_pickup: "En Route to Pickup",
  at_pickup: "At Pickup",
  loaded: "Loaded",
  en_route_to_delivery: "In Transit",
  at_delivery: "At Delivery",
  delivered: "Delivered",
  completed: "Delivered",
  cancelled: "Cancelled",
};

// Same tone-per-status the shared StatusBadge already uses for these exact
// values -- duplicated as a small local map (rather than exporting
// StatusBadge's internal one) so this file can show the board's own
// "In Transit"/"Delivered" labels instead of StatusBadge's generic
// underscore-to-titlecase text, without changing StatusBadge's behavior
// anywhere else it's used across the app.
const STATUS_TONE: Record<string, string> = {
  assigned: "text-desktop-warning",
  accepted: "text-desktop-warning",
  en_route_to_pickup: "text-secondary",
  at_pickup: "text-secondary",
  loaded: "text-secondary",
  en_route_to_delivery: "text-secondary",
  at_delivery: "text-secondary",
  delivered: "text-desktop-success",
  completed: "text-desktop-success",
  cancelled: "text-desktop-danger",
};

function DispatchStatusBadge({ status }: { status: string }) {
  return (
    <span className={`text-[12px] font-medium ${STATUS_TONE[status] ?? "text-muted-foreground"}`}>
      {STATUS_LABEL[status] ?? status}
    </span>
  );
}

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}
function fmtDateTime(iso: string | null): string {
  if (!iso) return "--";
  return new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

export function DispatchDrawer({ dispatchId, onClose }: { dispatchId: string | null; onClose: () => void }) {
  const [data, setData] = useState<DispatchDrawerData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const [noteOpen, setNoteOpen] = useState(false);
  const [noteText, setNoteText] = useState("");
  const [noteSaving, startNoteSave] = useTransition();
  const toast = useToast();

  useEffect(() => {
    if (!dispatchId) {
      setData(null);
      setError(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);
    setData(null);
    getDispatchDrawerData(dispatchId).then((result) => {
      if (cancelled) return;
      if ("error" in result) setError(result.error);
      else setData(result);
      setLoading(false);
    });
    return () => {
      cancelled = true;
    };
  }, [dispatchId]);

  // Phase 2I.1A section K -- lightweight 20s polling so a driver's reply
  // (or its read-state) surfaces without a manual close/reopen, using the
  // drawer's OWN existing narrow fetch (getDispatchDrawerData), never
  // router.refresh() or a new realtime/websocket channel. Guarded against
  // overlap (skips a tick if the previous fetch is still in flight) and
  // stops the moment the drawer closes or unmounts.
  useEffect(() => {
    if (!dispatchId) return;
    let cancelled = false;
    let inFlight = false;
    const interval = setInterval(() => {
      if (inFlight || cancelled) return;
      inFlight = true;
      getDispatchDrawerData(dispatchId)
        .then((fresh) => {
          if (cancelled) return;
          if (!("error" in fresh)) setData(fresh);
        })
        .finally(() => {
          inFlight = false;
        });
    }, 20000);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [dispatchId]);

  if (!dispatchId) return null;

  async function refresh() {
    if (!dispatchId) return;
    const fresh = await getDispatchDrawerData(dispatchId);
    if (!("error" in fresh)) setData(fresh);
  }

  function handleAddNote() {
    if (!dispatchId || !noteText.trim()) return;
    startNoteSave(async () => {
      const result = await addDispatchQuickNote(dispatchId, noteText);
      if (result.ok) {
        toast.show("success", "Note added.");
        setNoteText("");
        setNoteOpen(false);
        await refresh();
      } else {
        toast.show("error", result.error);
      }
    });
  }

  return (
    <>
      {/* Backdrop -- board stays visible behind it (spec: "board should
          remain visible behind it"), just dimmed. */}
      <div className="fixed inset-0 z-40 bg-black/20" onClick={onClose} aria-hidden />

      <div
        role="dialog"
        aria-modal="true"
        aria-label="Dispatch details"
        className="fixed right-0 top-0 z-50 flex h-full flex-col border-l border-desktop-border bg-desktop-panel shadow-elevation-3 transition-[width] duration-150"
        style={{ width: expanded ? "min(720px, 92vw)" : "min(480px, 92vw)" }}
      >
        {/* Header */}
        <div className="flex shrink-0 items-center justify-between gap-2 border-b border-desktop-border bg-desktop-header px-3 py-2.5 text-desktop-header-text">
          <div className="min-w-0">
            {/* Loading only while a request is actually in flight -- once
                it finishes (success or error), this must never keep
                claiming to still be loading. */}
            <p className="truncate text-sm font-semibold">
              {data ? data.load.loadNumber : loading ? "Loading..." : "Dispatch Details"}
            </p>
            {data && (
              <div className="mt-0.5">
                <DispatchStatusBadge status={data.dispatch.status} />
              </div>
            )}
          </div>
          <div className="flex shrink-0 items-center gap-1">
            <button
              type="button"
              onClick={() => setExpanded((e) => !e)}
              aria-label={expanded ? "Collapse drawer" : "Expand drawer"}
              className="rounded-sm p-1.5 hover:bg-white/10"
            >
              <ChevronsLeftRight className="size-4" />
            </button>
            <button type="button" onClick={onClose} aria-label="Close drawer" className="rounded-sm p-1.5 hover:bg-white/10">
              <X className="size-4" />
            </button>
          </div>
        </div>

        {loading && (
          <div className="flex flex-1 items-center justify-center">
            <Loader2 className="size-6 animate-spin text-muted-foreground" />
          </div>
        )}

        {error && (
          <div className="flex-1 p-4">
            <p className="text-sm text-danger">{error}</p>
          </div>
        )}

        {data && (
          <>
            {/* Phase 2I.1: Call/Message/Documents no longer navigate away
                (tel:/sms:) or leave the app -- all three scroll to an
                always-open section inside this SAME drawer (Part B1: "Do
                NOT navigate the dispatcher away from the Dispatch
                Board"). The actual tel: hand-off (Part B2) now lives
                inside the Communication panel's own "Call Driver" button,
                fired together with the origination log, not on this
                toolbar button. */}
            <div className="flex shrink-0 flex-wrap items-center gap-1.5 border-b border-desktop-border px-3 py-2">
              <QuickActionLink href="#drawer-communication" icon={Phone} label="Call" />
              <QuickActionLink href="#drawer-communication" icon={MessageSquare} label="Message" />
              <QuickActionLink href="#drawer-documents" icon={FileText} label={documentsToolbarLabel(data)} warn={documentsToolbarWarn(data)} />
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button size="sm" variant="outline">
                    <MoreHorizontal className="size-3.5" />
                  </Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end">
                  <DropdownMenuItem asChild>
                    <Link href={`/dispatch/${dispatchId}`}>Edit Dispatch / Open Full Dispatch</Link>
                  </DropdownMenuItem>
                  <DropdownMenuItem asChild>
                    <Link href={`/loads/${data.load.id}`}>Open Full Load</Link>
                  </DropdownMenuItem>
                  <DropdownMenuItem asChild>
                    <a href={`/dispatch/${dispatchId}/load-sheet`} target="_blank" rel="noopener noreferrer">
                      <Printer className="mr-1.5 size-3.5" /> Print Load Sheet
                    </a>
                  </DropdownMenuItem>
                  <DropdownMenuItem onSelect={(e) => { e.preventDefault(); setNoteOpen((o) => !o); }}>
                    <StickyNote className="mr-1.5 size-3.5" /> Add Note
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            </div>

            {/* Phase 2I.1 (Part A4/C8/D) -- delivered operational summary.
                Every value here is read straight from data the drawer
                already fetched (deliveredRetention/billingReadiness/POD
                status) -- never independently derived, per the approved
                design's own explicit instruction. */}
            {data.deliveredRetention && <DeliveredBanner data={data} />}

            {noteOpen && (
              <div className="shrink-0 border-b border-desktop-border px-3 py-2">
                <textarea
                  value={noteText}
                  onChange={(e) => setNoteText(e.target.value)}
                  rows={2}
                  placeholder="Add an internal note..."
                  className="w-full rounded-sm border border-desktop-border bg-desktop-panel px-2 py-1.5 text-[13px] outline-none focus-visible:border-primary"
                />
                <div className="mt-1.5 flex justify-end gap-1.5">
                  <Button size="sm" variant="ghost" onClick={() => setNoteOpen(false)}>
                    Cancel
                  </Button>
                  <Button size="sm" onClick={handleAddNote} disabled={noteSaving || !noteText.trim()}>
                    {noteSaving ? "Saving..." : "Save Note"}
                  </Button>
                </div>
              </div>
            )}

            {/* Sections */}
            <div className="flex-1 overflow-y-auto p-3">
              <CollapsibleSectionsProvider defaults={SECTION_DEFAULTS}>
                <div className="mb-2 flex justify-end">
                  <CollapsibleSectionsToolbar />
                </div>
                <div className="space-y-2.5">
                  <DesktopCollapsibleSection id="overview" title="Overview">
                    <OverviewSection data={data} />
                  </DesktopCollapsibleSection>

                  <DesktopCollapsibleSection id="driver_equipment" title="Driver & Equipment">
                    <DriverEquipmentSection data={data} />
                  </DesktopCollapsibleSection>

                  <DesktopCollapsibleSection id="communication" title="Communication" badge={unreadDriverMessageCount(data) || undefined} badgeTone="warning">
                    <div id="drawer-communication">
                      <CommunicationPanel
                        dispatchId={dispatchId}
                        driver={data.driver}
                        canManageDispatchOps={data.canManageDispatchOps}
                        activity={data.activity}
                        initialMessages={data.communication.messages}
                        initialHasMoreMessages={data.communication.hasMoreMessages}
                        onSent={refresh}
                      />
                    </div>
                  </DesktopCollapsibleSection>

                  <DesktopCollapsibleSection id="pickup" title="Pickup">
                    <StopSection stop={data.pickup} geofence={data.geofence.pickup} kind="pickup" dispatchId={dispatchId} onSaved={refresh} />
                  </DesktopCollapsibleSection>

                  <DesktopCollapsibleSection id="delivery" title="Delivery">
                    <StopSection stop={data.delivery} geofence={data.geofence.delivery} kind="delivery" dispatchId={dispatchId} onSaved={refresh} />
                  </DesktopCollapsibleSection>

                  <DesktopCollapsibleSection id="tracking" title="Tracking">
                    <TrackingSection data={data} dispatchId={dispatchId} onRefreshed={refresh} />
                  </DesktopCollapsibleSection>

                  <DesktopCollapsibleSection id="documents" title="Documents" badge={data.documents.filter((d) => d.doc).length || undefined}>
                    <div id="drawer-documents">
                      <DocumentsPanel
                        dispatchId={dispatchId}
                        loadId={data.load.id}
                        loadNumber={data.load.loadNumber}
                        documents={data.documents}
                        billingReadiness={data.billingReadiness}
                        canManageDispatchOps={data.canManageDispatchOps}
                        isDelivered={data.dispatch.status === "delivered" || data.dispatch.status === "completed"}
                        onRefresh={refresh}
                      />
                    </div>
                  </DesktopCollapsibleSection>

                  <DesktopCollapsibleSection id="activity" title="Activity" badge={data.activity.length || undefined}>
                    <ActivitySection activity={data.activity} />
                  </DesktopCollapsibleSection>
                </div>
              </CollapsibleSectionsProvider>
            </div>
          </>
        )}
      </div>
    </>
  );
}

function QuickActionLink({ href, icon: Icon, label, warn }: { href: string | null; icon: React.ComponentType<{ className?: string }>; label: string; warn?: boolean }) {
  if (!href) {
    return (
      <span className="inline-flex h-7 cursor-not-allowed items-center gap-1.5 rounded-sm border border-desktop-border px-2 text-xs font-medium text-muted-foreground opacity-50">
        <Icon className="size-3.5" /> {label}
      </span>
    );
  }
  return (
    <a href={href} className="inline-flex h-7 items-center gap-1.5 rounded-sm border border-desktop-border px-2 text-xs font-medium hover:bg-desktop-muted">
      <Icon className="size-3.5" /> {label}
      {warn && <span aria-hidden className="size-1.5 shrink-0 rounded-full bg-desktop-warning" />}
    </a>
  );
}

// Phase 2I.1 (Part C7) -- "Documents 2/3" (or a warning dot if the
// readiness RPC hasn't returned yet) -- denominator/numerator come
// straight from get_load_billing_readiness()'s own columns, never a
// separate document-count guess. POD is always required (unconditional
// in the canonical RPC); BOL/Rate Confirmation only count when that
// org's billing_document_requirements actually requires them.
function documentsRequiredCounts(data: DispatchDrawerData): { satisfied: number; total: number } | null {
  const r = data.billingReadiness;
  if (!r) return null;
  const total = 1 + (r.bolRequired ? 1 : 0) + (r.rateConfirmationRequired ? 1 : 0);
  const satisfied = (r.hasVerifiedPod ? 1 : 0) + (r.bolRequired && r.hasBol ? 1 : 0) + (r.rateConfirmationRequired && r.hasRateConfirmation ? 1 : 0);
  return { satisfied, total };
}
function documentsToolbarLabel(data: DispatchDrawerData): string {
  const counts = documentsRequiredCounts(data);
  return counts ? `Documents ${counts.satisfied}/${counts.total}` : "Documents";
}
function documentsToolbarWarn(data: DispatchDrawerData): boolean {
  const counts = documentsRequiredCounts(data);
  return counts ? counts.satisfied < counts.total : false;
}

// Phase 2I.1 (Part B8, badge on the Communication section header) --
// unread driver-sent messages only (a dispatcher cares about what THEY
// haven't seen, not their own sent count).
function unreadDriverMessageCount(data: DispatchDrawerData): number {
  return data.communication.messages.filter((m) => m.senderType === "driver" && !m.readAt).length;
}

// Phase 2I.1 (Part A4/C8/D) -- delivered operational summary banner.
// Every line reads directly from already-fetched drawer data (never a
// second interpretation of POD/billing/retention).
function DeliveredBanner({ data }: { data: DispatchDrawerData }) {
  const retention = data.deliveredRetention;
  if (!retention) return null;
  const pod = data.documents.find((d) => d.type === "pod")?.doc ?? null;
  const podLabel = pod ? (pod.is_verified ? "Verified" : pod.rejected_at ? "Rejected" : "Uploaded") : "Missing";
  const billingLabel = data.billingReadiness ? (data.billingReadiness.readyToBill ? "Ready to Bill" : "Documents Needed") : "--";

  return (
    <div className="shrink-0 border-b border-desktop-border bg-desktop-success/10 px-3 py-2 text-xs">
      <p className="font-semibold text-desktop-success">Delivered{retention.deliveredAtLabel ? `: ${retention.deliveredAtLabel}` : ""}</p>
      <div className="mt-1 grid grid-cols-3 gap-2">
        <span>
          POD: <span className="font-medium">{podLabel}</span>
        </span>
        <span>
          Billing: <span className="font-medium">{billingLabel}</span>
        </span>
        <span className="text-muted-foreground">{retention.countdown ? retention.countdown.compact + (retention.countdown.expired ? "" : " left") : "Board retention: --"}</span>
      </div>
    </div>
  );
}

function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <>
      <span className="text-muted-foreground">{label}</span>
      <span className="text-right font-medium">{value}</span>
    </>
  );
}

function OverviewSection({ data }: { data: DispatchDrawerData }) {
  return (
    <div className="grid grid-cols-2 gap-x-3 gap-y-1.5 text-[13px]">
      <Row label="Dispatch #" value={data.dispatch.id.slice(0, 8).toUpperCase()} />
      <Row label="Load #" value={data.load.loadNumber} />
      <Row label="Status" value={<DispatchStatusBadge status={data.dispatch.status} />} />
      <Row label="Broker / Customer" value={data.load.brokerName ?? data.load.customerName ?? "--"} />
      <Row label="Carrier" value={data.carrier.name} />
      <Row label="Total Miles" value={data.load.totalMiles ? Number(data.load.totalMiles).toLocaleString() : "--"} />
      {data.financials ? (
        <>
          <div className="col-span-2 mt-1 border-t border-desktop-border pt-1.5 text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
            Internal Financials -- Staff Only
          </div>
          <Row label="Revenue" value={money(data.financials.loadRate)} />
          <Row label="Carrier Cost" value={money(data.financials.carrierCost)} />
          <Row label="Dispatch Fee" value={`${money(data.financials.dispatchFeeAmount)} (${data.financials.dispatchFeePercentage}%)`} />
          <Row
            label="Estimated Profit"
            value={
              <span className={data.financials.estimatedProfit != null && data.financials.estimatedProfit < 0 ? "text-danger" : "text-desktop-success"}>
                {data.financials.estimatedProfit != null ? money(data.financials.estimatedProfit) : "--"}
              </span>
            }
          />
        </>
      ) : (
        <div className="col-span-2 mt-1 border-t border-desktop-border pt-1.5 text-[12px] text-muted-foreground">
          Financial details are not available for your role.
        </div>
      )}
    </div>
  );
}

function DriverEquipmentSection({ data }: { data: DispatchDrawerData }) {
  return (
    <div className="grid grid-cols-2 gap-x-3 gap-y-1.5 text-[13px]">
      <Row label="Driver" value={data.driver?.name ?? "-- Unassigned --"} />
      <Row label="Driver Phone" value={data.driver?.phone ?? "--"} />
      <Row label="Driver Status" value={data.driver ? <StatusBadge status={data.driver.status} /> : "--"} />
      <Row label="Truck" value={data.truck?.unitNumber ?? "-- Unassigned --"} />
      <Row label="Tractor Type" value={data.truck ? [data.truck.year, data.truck.make, data.truck.model].filter(Boolean).join(" ") || "--" : "--"} />
      <Row label="Trailer" value={data.trailer?.unitNumber ?? "--"} />
      {data.driver && (
        <div className="col-span-2 mt-1 flex gap-2 border-t border-desktop-border pt-1.5">
          <Link href={`/drivers/${data.driver.id}`} className="text-xs font-medium text-primary hover:underline">
            Open Driver Profile &rarr;
          </Link>
        </div>
      )}
    </div>
  );
}

const GEOFENCE_STATE_LABEL: Record<string, string> = {
  outside: "Outside",
  candidate_inside: "Approaching (confirming)",
  inside: "Inside",
  candidate_outside: "Leaving (confirming)",
  exited: "Departed",
};

function StopSection({
  stop,
  geofence,
  kind,
  dispatchId,
  onSaved,
}: {
  stop: DispatchDrawerData["pickup"];
  geofence: StopGeofenceInfo | null;
  kind: "pickup" | "delivery";
  dispatchId: string;
  onSaved: () => void | Promise<void>;
}) {
  const [, startTransition] = useTransition();
  const toast = useToast();

  if (!stop) return <p className="text-[13px] text-muted-foreground">No {kind} stop on this load.</p>;

  function markStatus(status: string) {
    startTransition(async () => {
      const result = await updateDispatchBoardStatus(dispatchId, status);
      if (result.ok) toast.show("success", `Marked ${STATUS_LABEL[status] ?? status}.`);
      else toast.show("error", result.error);
    });
  }

  return (
    <div className="space-y-2 text-[13px]">
      <div className="grid grid-cols-2 gap-x-3 gap-y-1.5">
        <Row label="Company" value={stop.companyName ?? "--"} />
        <Row label="City/State" value={[stop.city, stop.state].filter(Boolean).join(", ") || "--"} />
        <Row
          label="Appointment"
          value={stop.scheduledWindowEnd ? formatStopWindow(stop.scheduledAt, stop.scheduledWindowEnd, stop.timezone) : formatStopDateTime(stop.scheduledAt, stop.timezone)}
        />
        <Row label="Timezone" value={stop.timezone} />
        <Row label="Reference #" value={stop.referenceNumber ?? "--"} />
        <Row label="Contact" value={stop.contactName ?? "--"} />
        <Row label="Phone" value={stop.contactPhone ?? "--"} />
        <Row label="Arrival" value={formatStopDateTime(stop.arrivedAt, stop.timezone)} />
        <Row label="Departure" value={formatStopDateTime(stop.departedAt, stop.timezone)} />
      </div>
      {stop.timezoneIsFallback && (
        <p className="flex items-start gap-1.5 rounded-sm border border-desktop-border bg-desktop-muted/40 px-2 py-1.5 text-[11.5px] text-muted-foreground">
          <AlertTriangle className="mt-0.5 size-3 shrink-0" />
          Timezone was not stored when this appointment was created. Currently showing the organization&apos;s timezone
          ({stop.timezone}) as a fallback.
        </p>
      )}
      {stop.detention?.inDetention && (
        <div className="rounded-sm border border-warning/40 bg-warning/10 px-2 py-1.5 text-[12px] font-semibold text-warning">
          DETENTION -- {formatMinutes(stop.detention.minutes)}
        </div>
      )}

      <AppointmentEditor stop={stop} dispatchId={dispatchId} onSaved={onSaved} />

      <GeofenceBlock stop={stop} geofence={geofence} kind={kind} dispatchId={dispatchId} onSaved={onSaved} />

      <div className="flex flex-wrap gap-1.5 border-t border-desktop-border pt-2">
        {kind === "pickup" ? (
          <>
            <Button size="sm" variant="outline" onClick={() => markStatus("en_route_to_pickup")}>
              Mark En Route
            </Button>
            <Button size="sm" variant="outline" onClick={() => markStatus("at_pickup")}>
              Mark Arrived
            </Button>
            <Button size="sm" variant="outline" onClick={() => markStatus("loaded")}>
              Mark Loaded
            </Button>
          </>
        ) : (
          <>
            <Button size="sm" variant="outline" onClick={() => markStatus("at_delivery")}>
              Mark At Delivery
            </Button>
            <Button size="sm" variant="outline" onClick={() => markStatus("delivered")}>
              Mark Delivered
            </Button>
          </>
        )}
      </div>
    </div>
  );
}

// Phase 2B (spec section 20): distance/state/accuracy/arrival for this
// stop's geofence, plus a way to fix the single most common reason it's
// unavailable -- no coordinates on file yet (most pre-existing loads).
// Two distinct actions (spec sections 13/20/21), never conflated in the UI
// either: "Edit Appointment" recomputes the stored instant from a new
// local date/time/timezone (setStopAppointment, mode B). "Set Timezone"
// (legacy stops only) attaches timezone metadata WITHOUT touching the
// stored instant at all (setStopTimezone, mode A).
function AppointmentEditor({
  stop,
  dispatchId,
  onSaved,
}: {
  stop: NonNullable<DispatchDrawerData["pickup"]>;
  dispatchId: string;
  onSaved: () => void | Promise<void>;
}) {
  const [mode, setMode] = useState<"closed" | "edit" | "timezone-only">("closed");
  // Pre-filled from the stop's OWN timezone, never a raw UTC-string slice
  // (found live during Phase 2C.1 re-verification: an 11PM Pacific
  // appointment's UTC instant falls on the next calendar day, so a naive
  // `.slice(0, 10)` pre-filled the wrong date).
  const [date, setDate] = useState(() => stopLocalDateInputValue(stop.scheduledAt, stop.timezone));
  const [time, setTime] = useState(() => stopLocalTimeInputValue(stop.scheduledAt, stop.timezone));
  const [windowEndTime, setWindowEndTime] = useState(() => stopLocalTimeInputValue(stop.scheduledWindowEnd, stop.timezone));
  const [timezone, setTimezone] = useState(stop.timezone);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const toast = useToast();

  if (mode === "closed") {
    return (
      <div className="flex gap-3 text-[12px]">
        <button type="button" onClick={() => setMode("edit")} className="font-medium text-primary hover:underline">
          Edit Appointment
        </button>
        {stop.timezoneIsFallback && (
          <button type="button" onClick={() => setMode("timezone-only")} className="font-medium text-primary hover:underline">
            Set Timezone
          </button>
        )}
      </div>
    );
  }

  if (mode === "timezone-only") {
    return (
      <div className="space-y-1.5 rounded-sm border border-desktop-border bg-desktop-muted/30 p-2">
        <p className="text-[11.5px] text-muted-foreground">
          Sets the display timezone only -- the stored appointment time itself is not changed.
        </p>
        <select value={timezone} onChange={(e) => setTimezone(e.target.value)} className="h-7 w-full rounded-sm border border-desktop-border bg-card px-2 text-[12px]">
          {COMMON_TIMEZONES.map((tz) => (
            <option key={tz.value} value={tz.value}>{tz.label}</option>
          ))}
        </select>
        {error && <p className="text-[11px] text-danger">{error}</p>}
        <div className="flex gap-1.5">
          <Button
            size="sm"
            disabled={saving}
            onClick={async () => {
              setSaving(true);
              setError(null);
              const result = await setStopTimezone(dispatchId, stop.id, timezone);
              setSaving(false);
              if (result.ok) {
                toast.show("success", "Timezone saved.");
                setMode("closed");
                await onSaved();
              } else setError(result.error);
            }}
          >
            {saving ? "Saving..." : "Save"}
          </Button>
          <Button size="sm" variant="ghost" onClick={() => setMode("closed")} disabled={saving}>
            Cancel
          </Button>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-1.5 rounded-sm border border-desktop-border bg-desktop-muted/30 p-2">
      <div className="grid grid-cols-2 gap-1.5">
        <div className="space-y-0.5">
          <label className="text-[11px] font-medium text-muted-foreground">Date</label>
          <input type="date" value={date} onChange={(e) => setDate(e.target.value)} className="h-7 w-full rounded-sm border border-desktop-border bg-card px-2 text-[12px]" />
        </div>
        <div className="space-y-0.5">
          <label className="text-[11px] font-medium text-muted-foreground">Time</label>
          <input type="time" value={time} onChange={(e) => setTime(e.target.value)} className="h-7 w-full rounded-sm border border-desktop-border bg-card px-2 text-[12px]" />
        </div>
        <div className="space-y-0.5">
          <label className="text-[11px] font-medium text-muted-foreground">Window End (optional)</label>
          <input type="time" value={windowEndTime} onChange={(e) => setWindowEndTime(e.target.value)} className="h-7 w-full rounded-sm border border-desktop-border bg-card px-2 text-[12px]" />
        </div>
        <div className="space-y-0.5">
          <label className="text-[11px] font-medium text-muted-foreground">Timezone</label>
          <select value={timezone} onChange={(e) => setTimezone(e.target.value)} className="h-7 w-full rounded-sm border border-desktop-border bg-card px-2 text-[12px]">
            {COMMON_TIMEZONES.map((tz) => (
              <option key={tz.value} value={tz.value}>{tz.label}</option>
            ))}
          </select>
        </div>
      </div>
      {error && <p className="text-[11px] text-danger">{error}</p>}
      <div className="flex gap-1.5">
        <Button
          size="sm"
          disabled={saving || !date || !time}
          onClick={async () => {
            setSaving(true);
            setError(null);
            const result = await setStopAppointment(dispatchId, stop.id, { date, time, windowEndTime: windowEndTime || null, timezone });
            setSaving(false);
            if (result.ok) {
              toast.show("success", "Appointment saved.");
              setMode("closed");
              await onSaved();
            } else setError(result.error);
          }}
        >
          {saving ? "Saving..." : "Save"}
        </Button>
        <Button size="sm" variant="ghost" onClick={() => setMode("closed")} disabled={saving}>
          Cancel
        </Button>
      </div>
    </div>
  );
}

function GeofenceBlock({
  stop,
  geofence,
  kind,
  dispatchId,
  onSaved,
}: {
  stop: NonNullable<DispatchDrawerData["pickup"]>;
  geofence: StopGeofenceInfo | null;
  kind: "pickup" | "delivery";
  dispatchId: string;
  onSaved: () => void | Promise<void>;
}) {
  const [editing, setEditing] = useState(false);
  const [lat, setLat] = useState("");
  const [lon, setLon] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const toast = useToast();

  if (!geofence || !geofence.hasCoordinates) {
    return (
      <div className="rounded-sm border border-desktop-border bg-desktop-muted/40 px-2.5 py-2 text-[12px]">
        <p className="flex items-center gap-1.5 text-muted-foreground">
          <AlertTriangle className="size-3.5 shrink-0" /> Geofence unavailable -- stop coordinates missing.
        </p>
        {!editing ? (
          <button type="button" onClick={() => setEditing(true)} className="mt-1.5 text-[12px] font-medium text-primary hover:underline">
            Set Coordinates
          </button>
        ) : (
          <div className="mt-2 space-y-1.5">
            <div className="flex gap-1.5">
              <input
                value={lat}
                onChange={(e) => setLat(e.target.value)}
                placeholder="Latitude"
                inputMode="decimal"
                className="h-7 w-full rounded-sm border border-desktop-border bg-card px-2 text-[12px] outline-none focus-visible:border-primary"
              />
              <input
                value={lon}
                onChange={(e) => setLon(e.target.value)}
                placeholder="Longitude"
                inputMode="decimal"
                className="h-7 w-full rounded-sm border border-desktop-border bg-card px-2 text-[12px] outline-none focus-visible:border-primary"
              />
            </div>
            {error && <p className="text-[11px] text-danger">{error}</p>}
            <div className="flex gap-1.5">
              <Button
                size="sm"
                disabled={saving}
                onClick={async () => {
                  const latNum = Number(lat);
                  const lonNum = Number(lon);
                  if (!Number.isFinite(latNum) || !Number.isFinite(lonNum)) {
                    setError("Enter valid numbers for both fields.");
                    return;
                  }
                  setSaving(true);
                  setError(null);
                  const result = await setStopCoordinates(dispatchId, stop.id, latNum, lonNum);
                  setSaving(false);
                  if (result.ok) {
                    toast.show("success", "Coordinates saved. Geofence tracking is now active for this stop.");
                    setEditing(false);
                    await onSaved();
                  } else {
                    setError(result.error);
                  }
                }}
              >
                {saving ? "Saving..." : "Save"}
              </Button>
              <Button size="sm" variant="ghost" onClick={() => setEditing(false)} disabled={saving}>
                Cancel
              </Button>
            </div>
          </div>
        )}
      </div>
    );
  }

  return (
    <div className="rounded-sm border border-desktop-border bg-desktop-panel px-2.5 py-2 text-[12.5px]">
      <p className="mb-1.5 flex items-center gap-1.5 text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
        <Satellite className="size-3.5" /> {kind === "pickup" ? "Pickup" : "Delivery"} Geofence
      </p>
      <div className="grid grid-cols-2 gap-x-3 gap-y-1">
        <Row label="Distance" value={geofence.distanceM != null ? `${Math.round(geofence.distanceM)} m` : "--"} />
        <Row label="State" value={geofence.state ? GEOFENCE_STATE_LABEL[geofence.state] ?? geofence.state : "No data yet"} />
        <Row label="GPS Accuracy" value={geofence.accuracyM != null ? `${Math.round(geofence.accuracyM)} m` : "--"} />
        <Row
          label="Arrival"
          value={
            geofence.arrivalConfirmedAt
              ? geofence.statusApplied
                ? // Phase 2C.1 follow-up: this used to render via the
                  // browser-local fmtDateTime() -- the exact bug class
                  // Phase 2C.1 exists to fix, just missed on this one field.
                  // Render in the STOP's own timezone through the same
                  // centralized helper every other stop timestamp uses.
                  `Confirmed ${formatStopDateTime(geofence.arrivalConfirmedAt, stop.timezone)}`
                : "Detected -- awaiting driver confirmation"
              : "--"
          }
        />
      </div>
    </div>
  );
}

const RISK_LABEL: Record<string, string> = {
  unknown: "ETA UNKNOWN",
  on_time: "ON TIME",
  at_risk: "AT RISK",
  late: "LATE",
  arrived: "ARRIVED",
};
const RISK_TONE: Record<string, string> = {
  unknown: "border-desktop-border bg-desktop-muted/50 text-muted-foreground",
  on_time: "border-desktop-success/40 bg-desktop-success/10 text-desktop-success",
  at_risk: "border-warning/40 bg-warning/10 text-warning",
  late: "border-danger/40 bg-danger/10 text-danger",
  arrived: "border-desktop-success/40 bg-desktop-success/10 text-desktop-success",
};

function fmtAgo(iso: string | null): string {
  if (!iso) return "--";
  const minutes = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  if (minutes <= 0) return "just now";
  if (minutes < 60) return `${minutes} min ago`;
  return `${Math.round(minutes / 60)}h ago`;
}

function TrackingSection({ data, dispatchId, onRefreshed }: { data: DispatchDrawerData; dispatchId: string; onRefreshed: () => void | Promise<void> }) {
  const t = data.tracking;
  const r = data.routeIntelligence;
  const [refreshing, setRefreshing] = useState(false);
  const [refreshError, setRefreshError] = useState<string | null>(null);
  const toast = useToast();

  async function handleRefresh() {
    setRefreshing(true);
    setRefreshError(null);
    const result = await refreshDispatchEta(dispatchId);
    setRefreshing(false);
    if (result.ok) {
      toast.show("success", "ETA refreshed.");
      await onRefreshed();
    } else {
      setRefreshError(result.error);
    }
  }

  if (!t.available) {
    return (
      <div className="flex items-start gap-2 rounded-sm border border-desktop-border bg-desktop-muted/50 px-2.5 py-2 text-[12.5px] text-muted-foreground">
        <Radio className="mt-0.5 size-3.5 shrink-0" />
        <span>{t.reason || "Driver location not available."}</span>
      </div>
    );
  }

  return (
    <div className="space-y-2">
      {t.stale && (
        <div className="rounded-sm border border-warning/40 bg-warning/10 px-2 py-1.5 text-[12px] font-semibold text-warning">
          Location stale -- {t.reason.replace("Location stale -- ", "")}
        </div>
      )}
      <p className="text-[10.5px] font-semibold uppercase tracking-wide text-desktop-success">Live Tracking</p>

      {r && r.riskStatus === "arrived" ? (
        <div className="rounded-sm border border-desktop-success/40 bg-desktop-success/10 px-2.5 py-2">
          <p className="text-[13px] font-bold text-desktop-success">ARRIVED</p>
          <div className="mt-1 grid grid-cols-2 gap-x-3 gap-y-1 text-[13px]">
            <Row label="Appointment" value={formatStopDateTime(r.appointmentAt ?? r.appointmentWindowEnd, r.targetStopTimezone, { timeOnly: true })} />
          </div>
        </div>
      ) : r && r.calculationStatus === "no_coordinates" ? (
        <div className="flex items-start gap-1.5 rounded-sm border border-desktop-border bg-desktop-muted/40 px-2.5 py-2 text-[12px] text-muted-foreground">
          <AlertTriangle className="mt-0.5 size-3.5 shrink-0" /> Route ETA unavailable -- stop coordinates missing.
        </div>
      ) : r && r.estimatedArrivalAt ? (
        <div className="space-y-1.5">
          <div className="grid grid-cols-2 gap-x-3 gap-y-1.5 text-[13px]">
            <Row label="Next Stop" value={r.targetStopLabel ?? "--"} />
            <Row label="Miles Remaining" value={formatMiles(r.routeDistanceMeters)} />
            <Row label="ETA" value={formatStopDateTime(r.estimatedArrivalAt, r.targetStopTimezone, { timeOnly: true })} />
            <Row
              label="Appointment"
              value={
                r.appointmentAt
                  ? r.appointmentWindowEnd
                    ? `${formatStopDateTime(r.appointmentAt, r.targetStopTimezone, { timeOnly: true })}-${formatStopDateTime(r.appointmentWindowEnd, r.targetStopTimezone, { timeOnly: true })}`
                    : formatStopDateTime(r.appointmentAt, r.targetStopTimezone, { timeOnly: true })
                  : "Not set"
              }
            />
          </div>
          <div className={cn("rounded-sm border px-2 py-1.5 text-[12px] font-semibold", RISK_TONE[r.riskStatus])}>
            {RISK_LABEL[r.riskStatus]}
            {r.riskStatus === "late" && r.scheduleVarianceMinutes != null && ` -- ${formatLateLabel(r.scheduleVarianceMinutes)}`}
            {r.riskStatus === "on_time" && r.scheduleVarianceMinutes != null && formatMarginLabel(r.scheduleVarianceMinutes) && ` -- ${formatMarginLabel(r.scheduleVarianceMinutes)}`}
          </div>
          {r.progress != null && (
            <div className="flex items-center gap-1.5 text-[11px] text-muted-foreground">
              <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-desktop-muted">
                <div className="h-full rounded-full bg-primary" style={{ width: `${Math.round(r.progress * 100)}%` }} />
              </div>
              {Math.round(r.progress * 100)}%
            </div>
          )}
          <p className="text-[11px] text-muted-foreground">
            Route updated {fmtAgo(r.calculatedAt)}
            {r.calculationStatus === "provider_unavailable" && " (retrying -- showing last known route)"}
          </p>
        </div>
      ) : (
        <div className="flex items-start gap-1.5 rounded-sm border border-desktop-border bg-desktop-muted/40 px-2.5 py-2 text-[12px] text-muted-foreground">
          <AlertTriangle className="mt-0.5 size-3.5 shrink-0" /> Route ETA unavailable.
        </div>
      )}

      {data.routeDeviation && <RouteDeviationBlock deviation={data.routeDeviation} dispatchId={dispatchId} onDismissed={onRefreshed} />}

      <div className="grid grid-cols-2 gap-x-3 gap-y-1.5 border-t border-desktop-border pt-2 text-[13px]">
        <Row label="Last Location" value={<span className="flex items-center gap-1"><MapPin className="size-3.5" />{t.currentLocation ?? "--"}</span>} />
        <Row label="GPS Updated" value={fmtAgo(t.lastGpsUpdate)} />
        <Row label="Speed" value={t.speedMph != null ? `${t.speedMph} mph` : "--"} />
        <Row
          label="GPS Accuracy"
          value={
            <span className={t.lowAccuracy ? "text-warning" : undefined}>
              {t.accuracyMeters != null ? `${Math.round(t.accuracyMeters)} m` : "--"}
              {t.lowAccuracy && " (low)"}
            </span>
          }
        />
      </div>

      <div className="flex items-center gap-2 pt-1">
        <Link href="/tracking" className="text-xs font-medium text-primary hover:underline">
          View Live Map &rarr;
        </Link>
        <span className="text-desktop-border">|</span>
        <button type="button" onClick={handleRefresh} disabled={refreshing} className="text-xs font-medium text-primary hover:underline disabled:opacity-50">
          {refreshing ? "Refreshing..." : "Refresh ETA"}
        </button>
      </div>
      {refreshError && <p className="text-[11px] text-danger">{refreshError}</p>}
    </div>
  );
}

// Phase 2D. Deliberately its own small block, separate from the ETA/risk
// card above -- route status and schedule risk are different dimensions
// and must never be conflated into one badge (spec section 56: "OFF ROUTE
// / 27m LATE" both visible, one never replacing the other).
const DEVIATION_LABEL: Record<string, string> = {
  on_route: "ON ROUTE",
  candidate: "ROUTE CHECK",
  off_route: "OFF ROUTE",
  recovering: "RETURNING TO ROUTE",
  recovered: "RECOVERED",
};
const DEVIATION_TONE: Record<string, string> = {
  on_route: "border-desktop-success/40 bg-desktop-success/10 text-desktop-success",
  candidate: "border-desktop-border bg-desktop-muted/50 text-muted-foreground",
  off_route: "border-danger/40 bg-danger/10 text-danger",
  recovering: "border-warning/40 bg-warning/10 text-warning",
  recovered: "border-desktop-success/40 bg-desktop-success/10 text-desktop-success",
};

function RouteDeviationBlock({
  deviation,
  dispatchId,
  onDismissed,
}: {
  deviation: NonNullable<DispatchDrawerData["routeDeviation"]>;
  dispatchId: string;
  onDismissed: () => void | Promise<void>;
}) {
  const [dismissing, setDismissing] = useState(false);
  const toast = useToast();

  // Not evaluated / not currently trustworthy -- surfaced honestly rather
  // than a fabricated on/off-route claim (spec sections 6/7/18/20).
  if (deviation.calculationStatus !== "ok") {
    const reason =
      deviation.calculationStatus === "no_geometry"
        ? "Route deviation unavailable -- no calculated route yet."
        : deviation.calculationStatus === "low_accuracy"
          ? "Route deviation unavailable -- GPS accuracy too low."
          : deviation.calculationStatus === "stale_gps"
            ? "Route deviation status is stale -- GPS hasn't reported recently."
            : null; // 'arrived' -- monitoring is complete for this stop, nothing to show
    if (!reason) return null;
    return (
      <div className="flex items-start gap-1.5 rounded-sm border border-desktop-border bg-desktop-muted/40 px-2.5 py-2 text-[12px] text-muted-foreground">
        <AlertTriangle className="mt-0.5 size-3.5 shrink-0" /> {reason}
      </div>
    );
  }

  // "On route" with no history worth surfacing is deliberately quiet --
  // this block exists to flag exceptions, not to add noise to every drawer.
  if (deviation.state === "on_route" && !deviation.confirmedAt) return null;

  async function handleDismiss() {
    setDismissing(true);
    const result = await dismissRouteDeviation(dispatchId, deviation.targetStopId);
    setDismissing(false);
    if (result.ok) {
      toast.show("success", "Marked as a false positive.");
      await onDismissed();
    } else {
      toast.show("error", result.error);
    }
  }

  return (
    <div className={cn("rounded-sm border px-2.5 py-2", DEVIATION_TONE[deviation.state])}>
      <div className="flex items-center justify-between">
        <p className="text-[13px] font-bold">{DEVIATION_LABEL[deviation.state]}</p>
        {deviation.distanceFromRouteMeters != null && deviation.state !== "on_route" && (
          <p className="text-[12px] font-semibold">{formatMiles(deviation.distanceFromRouteMeters)}</p>
        )}
      </div>
      <div className="mt-1.5 grid grid-cols-2 gap-x-3 gap-y-1 text-[12.5px] text-desktop-text">
        {deviation.confirmedAt && <Row label="Detected" value={formatStopDateTime(deviation.confirmedAt, deviation.targetStopTimezone, { timeOnly: true })} />}
        {deviation.recoveredAt && <Row label="Recovered" value={formatStopDateTime(deviation.recoveredAt, deviation.targetStopTimezone, { timeOnly: true })} />}
      </div>
      {deviation.stale && (
        // Spec section 58: last-known state may keep showing, but staleness
        // must be unmistakable -- GPS hasn't reported recently enough to
        // trust this as a CURRENT claim.
        <p className="mt-1.5 flex items-center gap-1 text-[11px] font-medium opacity-80">
          <AlertTriangle className="size-3 shrink-0" /> Not current -- GPS hasn&apos;t reported recently.
        </p>
      )}
      {deviation.dismissedAt ? (
        <p className="mt-1.5 text-[11px] text-muted-foreground">Dismissed as a false positive.</p>
      ) : deviation.state === "off_route" ? (
        <button type="button" onClick={handleDismiss} disabled={dismissing} className="mt-1.5 text-[11px] font-medium underline decoration-dotted hover:text-desktop-text disabled:opacity-50">
          {dismissing ? "Dismissing..." : "Dismiss as false positive"}
        </button>
      ) : null}
    </div>
  );
}

function ActivitySection({ activity }: { activity: DispatchDrawerData["activity"] }) {
  if (activity.length === 0) return <p className="text-[13px] text-muted-foreground">No activity recorded yet.</p>;
  return (
    <div className="space-y-2">
      {activity.map((a) => (
        <div key={a.id} className="rounded-sm border border-desktop-border bg-desktop-panel px-2.5 py-2 text-[12.5px]">
          <p className="font-medium text-desktop-text">{describeActivity(a)}</p>
          <p className="mt-0.5 text-muted-foreground">
            {activityActorLabel(a)} &middot; {fmtDateTime(a.createdAt)}
          </p>
        </div>
      ))}
    </div>
  );
}

// Phase 2B: status changes and exceptions raised by GPS geofence automation
// (evaluate-geofences.ts) carry changes.source instead of a real actor_id --
// never presented as if a human made the change (spec section 23).
function activityActorLabel(a: DispatchDrawerData["activity"][number]): string {
  const source = a.changes && typeof a.changes === "object" ? (a.changes as { source?: string }).source : undefined;
  if (source === "system:gps") return "System (GPS)";
  if (source === "driver:confirm") return "Driver (GPS confirm)";
  return a.actorName ?? "System";
}

const GPS_ACTION_LABEL: Record<string, string> = {
  gps_exception: "GPS Exception",
  gps_arrival_suggested: "GPS Arrival Detected",
  gps_departure_suggested: "GPS Departure Detected",
  gps_geofence_confirmed_inside: "GPS Geofence Confirmed",
  gps_geofence_confirmed_exit: "GPS Geofence Exit Confirmed",
};

function describeActivity(a: DispatchDrawerData["activity"][number]): string {
  if (a.action === "status_changed" && a.changes && typeof a.changes === "object") {
    const c = a.changes as { old_value?: string; new_value?: string; label?: string };
    const from = c.old_value ? STATUS_LABEL[c.old_value] ?? c.old_value : "--";
    const to = c.new_value ? STATUS_LABEL[c.new_value] ?? c.new_value : "--";
    return c.label ? `${c.label} (${from} → ${to})` : `Moved from ${from} to ${to}`;
  }
  if (a.action === "note_added" && a.changes && typeof a.changes === "object") {
    const c = a.changes as { new_value?: string };
    return `Note added: ${c.new_value ?? ""}`;
  }
  if (GPS_ACTION_LABEL[a.action] && a.changes && typeof a.changes === "object") {
    const c = a.changes as { label?: string; type?: string };
    return c.label ?? GPS_ACTION_LABEL[a.action];
  }
  // Phase 2D: readable text with the real numbers, never a raw JSON dump
  // (spec section 23).
  if (a.action === "route_deviation_candidate_started" && a.changes && typeof a.changes === "object") {
    const c = a.changes as { distance_m?: number };
    return `Route deviation candidate started${c.distance_m != null ? ` -- ${formatMiles(c.distance_m)} from expected route` : ""}`;
  }
  if (a.action === "route_deviation_confirmed" && a.changes && typeof a.changes === "object") {
    const c = a.changes as { distance_m?: number };
    return `Route deviation detected${c.distance_m != null ? ` -- ${formatMiles(c.distance_m)} from expected route` : ""}`;
  }
  if (a.action === "route_deviation_recovered" && a.changes && typeof a.changes === "object") {
    const c = a.changes as { minutes_off_route?: number | null };
    return `Vehicle returned to expected route${c.minutes_off_route != null ? ` after ${c.minutes_off_route} min` : ""}`;
  }
  if (a.action === "route_recalculated_while_off_route") return "Route recalculated while vehicle was off route";
  if (a.action === "route_deviation_dismissed") return "Route deviation exception dismissed as false positive";
  return a.action.replace(/_/g, " ").replace(/\b\w/g, (ch) => ch.toUpperCase());
}
