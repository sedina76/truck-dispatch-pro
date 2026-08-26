"use client";

import { useEffect, useState, useTransition } from "react";
import Link from "next/link";
import { X, Loader2, AlertTriangle } from "lucide-react";
import { cn } from "@/lib/utils";
import { useToast } from "@/components/ui/toast";
import { getExceptionDetail, acknowledgeException, assignException, unassignException, resolveException, addExceptionNote } from "@/app/(app)/dispatch/exceptions/actions";
import { EXCEPTION_TYPE_LABEL, SEVERITY_LABEL, STATUS_LABEL, type ExceptionSeverity, type ExceptionStatus, type ExceptionType } from "@/lib/exceptions/types";
import { formatMinutes } from "@/lib/dispatch/detention";
import { formatMiles } from "@/lib/routing/risk";
import { formatStopDateTime } from "@/lib/timezone/format";

const RESOLUTION_REASONS = ["Driver contacted", "Dispatch corrected", "Appointment updated", "Customer notified", "Duplicate / not actionable", "Other"];

type ExceptionDetail = Awaited<ReturnType<typeof getExceptionDetail>>;

export function ExceptionDrawer({ exceptionId, onClose, onChanged, onSelectSibling }: { exceptionId: string; onClose: () => void; onChanged: () => void; onSelectSibling: (id: string) => void }) {
  const [detail, setDetail] = useState<ExceptionDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [isPending, startTransition] = useTransition();
  const [noteBody, setNoteBody] = useState("");
  const [resolveReason, setResolveReason] = useState(RESOLUTION_REASONS[0]);
  const [resolveNote, setResolveNote] = useState("");
  const [showResolveForm, setShowResolveForm] = useState(false);
  // Phase 2P.7 -- Section G: disable the mutating buttons for the
  // duration of the actual server call, not just during the post-mutation
  // refresh (isPending/useTransition only covers that second part) -- a
  // rapid double-click on Acknowledge/Assign/Resolve is otherwise still
  // possible to fire twice before the first response returns. The
  // underlying actions are already idempotent/guarded at the DB level
  // either way; this is UX prevention, not the safety boundary.
  const [actionPending, setActionPending] = useState(false);
  const toast = useToast();

  async function load() {
    setLoading(true);
    const result = await getExceptionDetail(exceptionId);
    setDetail(result);
    setLoading(false);
  }

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [exceptionId]);

  function refreshAfterMutation() {
    startTransition(async () => {
      await load();
      onChanged();
    });
  }

  async function handleAcknowledge() {
    if (actionPending) return;
    setActionPending(true);
    try {
      const result = await acknowledgeException(exceptionId);
      if (result.ok) {
        toast.show("success", "Acknowledged.");
        refreshAfterMutation();
      } else toast.show("error", result.error);
    } finally {
      setActionPending(false);
    }
  }

  async function handleAssign(assigneeId: string) {
    if (actionPending) return;
    setActionPending(true);
    try {
      const result = await assignException(exceptionId, assigneeId);
      if (result.ok) {
        toast.show("success", "Assigned.");
        refreshAfterMutation();
      } else toast.show("error", result.error);
    } finally {
      setActionPending(false);
    }
  }

  async function handleUnassign() {
    if (actionPending) return;
    setActionPending(true);
    try {
      const result = await unassignException(exceptionId);
      if (result.ok) {
        toast.show("success", "Unassigned.");
        refreshAfterMutation();
      } else toast.show("error", result.error);
    } finally {
      setActionPending(false);
    }
  }

  if (loading || !detail) {
    return (
      <div className="fixed inset-y-0 right-0 z-50 flex w-full max-w-md items-center justify-center border-l border-desktop-border bg-desktop-panel shadow-elevation-3">
        <Loader2 className="size-5 animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (!detail.ok) {
    return (
      <div className="fixed inset-y-0 right-0 z-50 w-full max-w-md border-l border-desktop-border bg-desktop-panel p-4 shadow-elevation-3">
        <button type="button" onClick={onClose} className="mb-3">
          <X className="size-4" />
        </button>
        <p className="text-[13px] text-danger">{detail.error}</p>
      </div>
    );
  }

  const row = detail.row;
  const exceptionType = row.exception_type as ExceptionType;
  const severity = row.severity as ExceptionSeverity;
  const status = row.status as ExceptionStatus;
  const dispatch = row.dispatches as { id: string; status: string; loads: { id: string; load_number: string; load_stops: LoadStopRow[] } | null; trucks: { unit_number: string } | null; drivers: { id: string; first_name: string; last_name: string } | null } | null;
  const targetStopId = detail.liveRouteIntelligence?.target_stop_id ?? detail.liveRouteDeviation ? row.metadata?.target_stop_id : null;
  const targetStop = dispatch?.loads?.load_stops?.find((s) => s.id === targetStopId) ?? null;

  return (
    <div className="fixed inset-y-0 right-0 z-50 flex w-full max-w-md flex-col border-l border-desktop-border bg-desktop-panel shadow-elevation-3">
      <div className="flex items-center justify-between border-b border-desktop-border bg-primary px-4 py-3 text-primary-foreground">
        <div>
          <p className="text-[13px] font-bold">{EXCEPTION_TYPE_LABEL[exceptionType]}</p>
          <p className="text-[11px] opacity-80">{dispatch?.loads?.load_number ?? "--"}</p>
        </div>
        <button type="button" onClick={onClose}>
          <X className="size-4" />
        </button>
      </div>

      <div className={cn("flex-1 space-y-4 overflow-y-auto p-4 text-[12.5px]", isPending && "opacity-60")}>
        <div className="flex flex-wrap gap-2">
          <Badge tone={SEVERITY_TONE[severity]}>{SEVERITY_LABEL[severity]}</Badge>
          <Badge tone={STATUS_TONE[status]}>{STATUS_LABEL[status]}</Badge>
          {/* Phase 2P.7 -- row.escalated_at already comes back from
              getExceptionDetail()'s select("*") on the raw table; text +
              icon, never color alone. */}
          {row.escalated_at && (
            <Badge tone="bg-danger/15 text-danger">
              <AlertTriangle className="size-3 shrink-0" /> Escalated
            </Badge>
          )}
          <span className="ml-auto text-muted-foreground">Age {formatAge(row.first_detected_at)}</span>
        </div>

        {row.summary && <p className="text-desktop-text">{row.summary}</p>}

        {detail.siblingExceptions.length > 0 && (
          // Spec section 8: the main table compresses a compound incident
          // to one row, but the drawer must still show every contributing
          // condition -- each chip switches this same drawer to that
          // sibling episode's own record (independently addressable for
          // Acknowledge/Assign/Resolve).
          <div>
            <p className="mb-1 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">Also Active On This Dispatch</p>
            <div className="flex flex-wrap gap-1.5">
              {detail.siblingExceptions.map((s) => (
                <button
                  key={s.id}
                  type="button"
                  onClick={() => onSelectSibling(s.id)}
                  className={cn("rounded-sm border px-1.5 py-0.5 text-[10.5px] font-bold uppercase hover:opacity-80", SEVERITY_TONE[s.severity as ExceptionSeverity])}
                >
                  {EXCEPTION_TYPE_LABEL[s.exception_type as ExceptionType]}
                </button>
              ))}
            </div>
          </div>
        )}

        <Section title="Load / Truck / Driver">
          <Row label="Load" value={dispatch?.loads?.load_number ?? "--"} />
          <Row label="Truck" value={dispatch?.trucks?.unit_number ?? "--"} />
          <Row label="Driver" value={dispatch?.drivers ? `${dispatch.drivers.first_name} ${dispatch.drivers.last_name}` : "--"} />
          <Row label="Status" value={dispatch?.status ?? "--"} />
        </Section>

        {/* Source-specific detail -- always re-fetched live (spec sections
            26-30), never trusted from the row's own denormalized metadata. */}
        {exceptionType === "off_route" && detail.liveRouteDeviation && (
          <Section title="Off Route Detail">
            <Row label="Distance from route" value={detail.liveRouteDeviation.distance_from_route_m != null ? formatMiles(detail.liveRouteDeviation.distance_from_route_m) : "--"} />
            <Row label="Detected" value={detail.liveRouteDeviation.confirmed_at ? formatStopDateTime(detail.liveRouteDeviation.confirmed_at, targetStop?.timezone ?? "UTC", { timeOnly: true }) : "--"} />
            <Row label="Current status" value={detail.liveRouteDeviation.state} />
            <Row label="Last GPS" value={detail.liveRouteDeviation.last_location_at ? formatStopDateTime(detail.liveRouteDeviation.last_location_at, targetStop?.timezone ?? "UTC", { timeOnly: true }) : "--"} />
          </Section>
        )}

        {(exceptionType === "late" || exceptionType === "at_risk") && detail.liveRouteIntelligence && (
          <Section title={exceptionType === "late" ? "Late Detail" : "At Risk Detail"}>
            <Row label="Appointment" value={targetStop?.scheduled_at ? formatStopDateTime(targetStop.scheduled_at, targetStop.timezone ?? "UTC") : "--"} />
            <Row label="ETA" value={detail.liveRouteIntelligence.estimated_arrival_at ? formatStopDateTime(detail.liveRouteIntelligence.estimated_arrival_at, targetStop?.timezone ?? "UTC") : "--"} />
            <Row
              label="Difference"
              value={detail.liveRouteIntelligence.schedule_variance_minutes != null ? `${detail.liveRouteIntelligence.schedule_variance_minutes > 0 ? "+" : ""}${detail.liveRouteIntelligence.schedule_variance_minutes}m` : "--"}
            />
            <Row label="Miles remaining" value={detail.liveRouteIntelligence.route_distance_meters != null ? formatMiles(detail.liveRouteIntelligence.route_distance_meters) : "--"} />
          </Section>
        )}

        {exceptionType === "detention" && targetStop && (
          <Section title="Detention Detail">
            <Row label="Stop" value={targetStop.facility_name || [targetStop.city, targetStop.state].filter(Boolean).join(", ")} />
            <Row label="Arrived" value={targetStop.arrived_at ? formatStopDateTime(targetStop.arrived_at, targetStop.timezone ?? "UTC") : "--"} />
            <Row label="Departed" value={targetStop.departed_at ? formatStopDateTime(targetStop.departed_at, targetStop.timezone ?? "UTC") : "Still on site"} />
            <Row label="Over free time" value={row.metadata?.minutes_over != null ? formatMinutes(row.metadata.minutes_over as number) : "--"} />
          </Section>
        )}

        {exceptionType === "gps_stale" && (
          <Section title="GPS Stale Detail">
            <Row label="Last location" value={row.metadata?.last_location_at ? formatStopDateTime(row.metadata.last_location_at as string, "UTC") : "--"} />
            <Row label="Age" value={row.metadata?.stale_minutes != null ? `${row.metadata.stale_minutes}m` : "--"} />
          </Section>
        )}

        {exceptionType === "pod_missing" && (
          <Section title="POD Missing Detail">
            <Row label="Document state" value="No POD on file" />
          </Section>
        )}

        {/* Phase 2P.5 -- carrier-sourced exceptions (2P.4's insurance_policy
            and 0063's original compliance_item source_types both write
            exception_type='compliance'). Live-refetched from the real
            source table, same discipline as every other section here --
            never trusted from the row's own metadata snapshot. */}
        {exceptionType === "compliance" && detail.carrierContext && (
          <Section title="Compliance Detail">
            <Row label="Carrier" value={detail.carrierContext.legalName} />
            {detail.liveInsurancePolicy && (
              <>
                <Row label="Policy type" value={detail.liveInsurancePolicy.policy_type.replace(/_/g, " ")} />
                <Row label="Expires" value={detail.liveInsurancePolicy.expiry_date ? formatStopDateTime(detail.liveInsurancePolicy.expiry_date, "UTC", { timeOnly: false }) : "No expiry on file"} />
              </>
            )}
            {detail.liveComplianceItem && (
              <>
                <Row label="Item type" value={detail.liveComplianceItem.item_type.replace(/_/g, " ")} />
                <Row label="Current status" value={detail.liveComplianceItem.status.replace(/_/g, " ")} />
                <Row label="Expires" value={detail.liveComplianceItem.expiry_date ? formatStopDateTime(detail.liveComplianceItem.expiry_date, "UTC", { timeOnly: false }) : "No expiry on file"} />
              </>
            )}
          </Section>
        )}

        <Section title="Assignment">
          <Row label="Assigned to" value={row.assigned_to ? staffName(detail.staff, row.assigned_to) : "Unassigned"} />
          <div className="mt-1 flex flex-wrap items-center gap-2">
            {row.assigned_to !== detail.currentUserId && (
              <button type="button" disabled={actionPending} onClick={() => handleAssign(detail.currentUserId)} className="rounded-sm border border-desktop-border px-2 py-1 text-[12px] font-medium hover:bg-desktop-muted disabled:opacity-50">
                Assign to Me
              </button>
            )}
            {row.assigned_to && (
              <button type="button" disabled={actionPending} onClick={handleUnassign} className="rounded-sm border border-desktop-border px-2 py-1 text-[12px] font-medium hover:bg-desktop-muted disabled:opacity-50">
                Unassign
              </button>
            )}
            <select
              defaultValue=""
              disabled={actionPending}
              onChange={(e) => {
                if (!e.target.value) return;
                handleAssign(e.target.value);
                e.target.value = "";
              }}
              className="h-7 rounded-sm border border-desktop-border bg-background px-1.5 text-[12px] disabled:opacity-50"
            >
              <option value="">Reassign to...</option>
              {detail.staff.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.full_name}
                </option>
              ))}
            </select>
          </div>
        </Section>

        <Section title="Notes">
          <div className="space-y-2">
            {detail.notes.length === 0 && <p className="text-muted-foreground">No notes yet.</p>}
            {detail.notes.map((n) => {
              const author = Array.isArray(n.profiles) ? n.profiles[0] : n.profiles;
              return (
                <div key={n.id} className="rounded-sm border border-desktop-border bg-desktop-panel px-2 py-1.5">
                  <p className="text-desktop-text">{n.body}</p>
                  <p className="mt-0.5 text-[10.5px] text-muted-foreground">
                    {author?.full_name ?? "Staff"} -- {formatStopDateTime(n.created_at, "UTC", { timeOnly: true })}
                  </p>
                </div>
              );
            })}
          </div>
          <div className="mt-2 flex gap-2">
            <input value={noteBody} onChange={(e) => setNoteBody(e.target.value)} disabled={actionPending} placeholder="Add a note..." className="h-7 flex-1 rounded-sm border border-desktop-border bg-background px-2 text-[12px] disabled:opacity-50" />
            <button
              type="button"
              disabled={actionPending}
              onClick={async () => {
                if (!noteBody.trim() || actionPending) return;
                setActionPending(true);
                try {
                  const result = await addExceptionNote(exceptionId, noteBody);
                  if (result.ok) {
                    setNoteBody("");
                    refreshAfterMutation();
                  } else toast.show("error", result.error);
                } finally {
                  setActionPending(false);
                }
              }}
              className="rounded-sm border border-desktop-border px-2 text-[12px] font-medium hover:bg-desktop-muted disabled:opacity-50"
            >
              Add
            </button>
          </div>
        </Section>

        <Section title="Activity">
          <div className="space-y-1.5">
            {detail.activity.length === 0 && <p className="text-muted-foreground">No activity recorded.</p>}
            {detail.activity
              .filter((a) => (a.changes as Record<string, unknown> | null)?.exception_id === exceptionId || /^exception_/.test(a.action))
              .map((a) => (
                <p key={a.id} className="text-[11.5px] text-muted-foreground">
                  <span className="font-medium text-desktop-text">{a.actor_id ? "Staff" : "System"}</span> {a.action.replace(/_/g, " ")} -- {formatStopDateTime(a.created_at, "UTC", { timeOnly: true })}
                </p>
              ))}
          </div>
        </Section>
      </div>

      <div className="space-y-2 border-t border-desktop-border p-3">
        {!showResolveForm ? (
          <div className="flex flex-wrap gap-2">
            {status === "open" && (
              <ActionButton onClick={handleAcknowledge} label="Acknowledge" disabled={actionPending} />
            )}
            {status !== "resolved" && <ActionButton onClick={() => setShowResolveForm(true)} label="Resolve" disabled={actionPending} />}
            {dispatch && (
              <Link href={`/dispatch/${dispatch.id}`} className="rounded-sm border border-desktop-border px-2.5 py-1.5 text-[12px] font-medium hover:bg-desktop-muted">
                Open Dispatch
              </Link>
            )}
            {/* Phase 2P.7 -- direct drill-through to the existing load/
                driver detail pages (no new destination pages), using the
                ids now selected alongside load_number/first_name/last_name.
                Existing route/RLS boundary is the only authorization here,
                same as every other link in this drawer. */}
            {dispatch?.loads?.id && (
              <Link href={`/loads/${dispatch.loads.id}`} className="rounded-sm border border-desktop-border px-2.5 py-1.5 text-[12px] font-medium hover:bg-desktop-muted">
                View Load
              </Link>
            )}
            {dispatch?.drivers?.id && (
              <Link href={`/drivers/${dispatch.drivers.id}`} className="rounded-sm border border-desktop-border px-2.5 py-1.5 text-[12px] font-medium hover:bg-desktop-muted">
                View Driver
              </Link>
            )}
            {dispatch && (
              <Link href="/tracking" className="rounded-sm border border-desktop-border px-2.5 py-1.5 text-[12px] font-medium hover:bg-desktop-muted">
                View Live Map
              </Link>
            )}
            {!dispatch && detail.carrierContext && (
              <Link href={`/carriers/${detail.carrierContext.id}`} className="rounded-sm border border-desktop-border px-2.5 py-1.5 text-[12px] font-medium hover:bg-desktop-muted">
                View Carrier
              </Link>
            )}
          </div>
        ) : (
          <div className="space-y-2">
            <select value={resolveReason} onChange={(e) => setResolveReason(e.target.value)} className="h-8 w-full rounded-sm border border-desktop-border bg-background px-2 text-[12.5px]">
              {RESOLUTION_REASONS.map((r) => (
                <option key={r} value={r}>
                  {r}
                </option>
              ))}
            </select>
            <textarea value={resolveNote} onChange={(e) => setResolveNote(e.target.value)} placeholder="Resolution note (optional)" className="h-16 w-full rounded-sm border border-desktop-border bg-background px-2 py-1 text-[12.5px]" />
            {status !== "resolved" && exceptionType === "off_route" && detail.liveRouteDeviation?.state === "off_route" && (
              <p className="flex items-center gap-1 text-[11px] text-warning">
                <AlertTriangle className="size-3 shrink-0" /> Resolved -- source condition still active.
              </p>
            )}
            <div className="flex gap-2">
              <button
                type="button"
                disabled={actionPending}
                onClick={async () => {
                  if (actionPending) return;
                  setActionPending(true);
                  try {
                    const result = await resolveException(exceptionId, resolveReason, resolveNote || null);
                    if (result.ok) {
                      toast.show("success", "Resolved.");
                      setShowResolveForm(false);
                      refreshAfterMutation();
                    } else toast.show("error", result.error);
                  } finally {
                    setActionPending(false);
                  }
                }}
                className="rounded-sm bg-primary px-2.5 py-1.5 text-[12px] font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
              >
                Confirm Resolve
              </button>
              <button type="button" disabled={actionPending} onClick={() => setShowResolveForm(false)} className="rounded-sm border border-desktop-border px-2.5 py-1.5 text-[12px] disabled:opacity-50">
                Cancel
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

type LoadStopRow = {
  id: string;
  stop_type: string;
  facility_name: string | null;
  city: string | null;
  state: string | null;
  scheduled_at: string | null;
  timezone: string | null;
  arrived_at: string | null;
  departed_at: string | null;
};

const SEVERITY_TONE: Record<ExceptionSeverity, string> = { critical: "bg-danger/15 text-danger", high: "bg-danger/10 text-danger", medium: "bg-warning/15 text-warning", low: "bg-desktop-muted text-muted-foreground" };
const STATUS_TONE: Record<ExceptionStatus, string> = { open: "bg-danger/10 text-danger", acknowledged: "bg-warning/15 text-warning", resolved: "bg-success/10 text-success" };

function Badge({ tone, children }: { tone: string; children: React.ReactNode }) {
  return <span className={cn("inline-flex items-center rounded-sm px-1.5 py-0.5 text-[10.5px] font-bold uppercase", tone)}>{children}</span>;
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div>
      <p className="mb-1 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">{title}</p>
      <div className="space-y-1">{children}</div>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  // Phase 2P.5B: min-w-0 + wrap-break-word -- a long carrier legal_name
  // (new Compliance Detail section) must wrap onto multiple lines inside
  // this fixed max-w-md drawer rather than overflow/clip. Every prior
  // usage (load number, truck unit, etc.) stays visually identical since
  // those values were always short enough to render on one line anyway.
  return (
    <div className="flex items-start justify-between gap-2">
      <span className="shrink-0 text-muted-foreground">{label}</span>
      <span className="min-w-0 wrap-break-word text-right font-medium text-desktop-text">{value}</span>
    </div>
  );
}

function ActionButton({ onClick, label, disabled }: { onClick: () => void; label: string; disabled?: boolean }) {
  return (
    <button type="button" onClick={onClick} disabled={disabled} className="rounded-sm bg-primary px-2.5 py-1.5 text-[12px] font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50">
      {label}
    </button>
  );
}

function formatAge(iso: string): string {
  const ms = Date.now() - new Date(iso).getTime();
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 60) return `${Math.max(0, minutes)}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ${minutes % 60}m`;
  return `${Math.floor(hours / 24)}d`;
}

function staffName(staff: { id: string; full_name: string }[], id: string): string {
  const s = staff.find((x) => x.id === id);
  return s ? s.full_name : "--";
}
