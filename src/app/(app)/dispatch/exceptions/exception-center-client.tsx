"use client";

import { useState, useTransition, useCallback } from "react";
import { useRouter } from "next/navigation";
import { RotateCcw, AlertTriangle } from "lucide-react";
import { cn } from "@/lib/utils";
import { KpiCard } from "@/components/ui/kpi-card";
import { EmptyState } from "@/components/ui/empty-state";
import { getExceptionCenterData, type ExceptionCenterResult, type ExceptionFilters } from "./actions";
import { EXCEPTION_TYPE_LABEL, SEVERITY_LABEL, type ExceptionListRow, type ExceptionSeverity } from "@/lib/exceptions/types";
import { ExceptionDrawer } from "@/components/dispatch/exception-drawer";

const SEVERITY_TONE: Record<ExceptionSeverity, string> = {
  critical: "bg-danger/15 text-danger border-danger/30",
  high: "bg-danger/10 text-danger border-danger/20",
  medium: "bg-warning/15 text-warning border-warning/30",
  low: "bg-desktop-muted text-muted-foreground border-desktop-border",
};

const STATUS_TONE: Record<string, string> = {
  open: "bg-danger/10 text-danger",
  acknowledged: "bg-warning/15 text-warning",
  resolved: "bg-success/10 text-success",
};

function formatAge(iso: string): string {
  const ms = Date.now() - new Date(iso).getTime();
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 60) return `${Math.max(0, minutes)}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ${minutes % 60}m`;
  const days = Math.floor(hours / 24);
  return `${days}d`;
}

// Compound display (spec section 8/review item 4): grouping itself now
// happens at the SQL layer (operational_exceptions_grouped, migration
// 0063) -- each row from getExceptionCenterData() is already one
// operational INCIDENT, deterministically led by its highest-severity
// contributing exception, correct regardless of pagination boundaries.
// This is purely a label formatter over that already-grouped data now,
// not a client-side grouping pass.
function compoundTitle(row: ExceptionListRow): string {
  const others = row.exceptionTypes.filter((t) => t !== row.exceptionType);
  if (others.length === 0) return row.title;
  return `${row.title} + ${others.map((t) => EXCEPTION_TYPE_LABEL[t].toUpperCase()).join(" + ")}`;
}

export function ExceptionCenterClient({
  initialData,
  initialFilters,
  initialOpenExceptionId,
}: {
  initialData: ExceptionCenterResult;
  initialFilters: ExceptionFilters;
  // Phase 2P.6B -- ?exception=<uuid> from a notification click-through
  // (see notifications-menu.tsx). The drawer itself independently
  // re-checks org/role access (getExceptionDetail(), RLS-backed) -- a
  // foreign-org or random uuid here just renders the drawer's own
  // existing "Exception not found." state, never a crash or data leak.
  initialOpenExceptionId?: string | null;
}) {
  const router = useRouter();
  const [data, setData] = useState(initialData);
  const [filters, setFilters] = useState<ExceptionFilters>(initialFilters);
  const [isPending, startTransition] = useTransition();
  const [openExceptionId, setOpenExceptionId] = useState<string | null>(initialOpenExceptionId ?? null);

  const applyFilters = useCallback((next: ExceptionFilters) => {
    setFilters(next);
    startTransition(async () => {
      const result = await getExceptionCenterData(next);
      setData(result);
    });
  }, []);

  const displayRows = data.ok ? data.rows : [];

  if (!data.ok) {
    return (
      <div className="p-6">
        <EmptyState title="Exception Center unavailable" description={data.error} />
      </div>
    );
  }

  const clearFilters = () => applyFilters({ page: 1, sort: "severity", severity: "all", status: "all", type: "all", assignment: "all", escalatedOnly: false, q: "" });

  // Phase 2P.7 -- Section J: distinguishable empty-state copy per the
  // active filter combination, rather than one generic message for every
  // case. Checked in a deliberate order (most specific intent first) so a
  // dispatcher immediately understands WHY the list is empty.
  const hasCustomFilters = Boolean(filters.q?.trim()) || (filters.type && filters.type !== "all") || filters.escalatedOnly;
  let emptyStateTitle = "No exceptions";
  let emptyStateDescription = "Nothing matches the current filters.";
  if (!hasCustomFilters && filters.assignment === "mine") {
    emptyStateTitle = "No exceptions assigned to you";
    emptyStateDescription = "You're not currently the owner of any open or acknowledged exception.";
  } else if (!hasCustomFilters && filters.assignment === "unassigned") {
    emptyStateTitle = "No unassigned exceptions";
    emptyStateDescription = "Every open exception currently has an owner.";
  } else if (!hasCustomFilters && filters.status === "resolved") {
    emptyStateTitle = "No resolved exceptions";
    emptyStateDescription = "Nothing has been resolved yet for the current filters.";
  } else if (!hasCustomFilters && (!filters.status || filters.status === "all") && (!filters.severity || filters.severity === "all")) {
    emptyStateTitle = "No open exceptions";
    emptyStateDescription = "Nothing currently needs attention.";
  }

  return (
    <div className="space-y-4 p-4 md:p-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-lg font-bold text-desktop-text">Exception Center</h1>
          <p className="text-[12.5px] text-muted-foreground">Operational problems across active dispatches -- triage, assign, and resolve.</p>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-2 md:grid-cols-3 lg:grid-cols-6">
        <button type="button" onClick={() => applyFilters({ ...filters, status: "all", severity: "all", assignment: "all", escalatedOnly: false, page: 1 })} className="text-left">
          <KpiCard label="Active Exceptions" value={data.kpis.active} tone={data.kpis.active > 0 ? "warning" : "neutral"} />
        </button>
        <button type="button" onClick={() => applyFilters({ ...filters, severity: "critical", status: "all", assignment: "all", escalatedOnly: false, page: 1 })} className="text-left">
          <KpiCard label="Critical" value={data.kpis.critical} tone={data.kpis.critical > 0 ? "danger" : "neutral"} />
        </button>
        <button type="button" onClick={() => applyFilters({ ...filters, status: "open", severity: "all", assignment: "all", escalatedOnly: false, page: 1 })} className="text-left">
          <KpiCard label="Unacknowledged" value={data.kpis.unacknowledged} tone={data.kpis.unacknowledged > 0 ? "warning" : "neutral"} />
        </button>
        {/* Phase 2P.7 -- Section E: dispatchers need to quickly find work
            nobody owns, same shortcut-tile pattern as the others here. */}
        <button type="button" onClick={() => applyFilters({ ...filters, assignment: "unassigned", status: "all", severity: "all", escalatedOnly: false, page: 1 })} className="text-left">
          <KpiCard label="Unassigned" value={data.kpis.unassigned} tone={data.kpis.unassigned > 0 ? "warning" : "neutral"} />
        </button>
        <button type="button" onClick={() => applyFilters({ ...filters, assignment: "mine", status: "all", severity: "all", escalatedOnly: false, page: 1 })} className="text-left">
          <KpiCard label="Assigned to Me" value={data.kpis.assignedToMe} />
        </button>
        <button type="button" onClick={() => applyFilters({ ...filters, status: "resolved", severity: "all", assignment: "all", escalatedOnly: false, page: 1 })} className="text-left">
          <KpiCard label="Resolved Today" value={data.kpis.resolvedToday} tone="success" />
        </button>
      </div>

      <div className="flex flex-wrap items-center gap-2 rounded-md border border-desktop-border bg-card p-2.5">
        <FilterSelect
          label="Severity"
          value={filters.severity ?? "all"}
          options={[
            ["all", "All"],
            ["critical", "Critical"],
            ["high", "High"],
            ["medium", "Medium"],
            ["low", "Low"],
          ]}
          onChange={(v) => applyFilters({ ...filters, severity: v as ExceptionFilters["severity"], page: 1 })}
        />
        <FilterSelect
          label="Status"
          value={filters.status ?? "all"}
          options={[
            ["all", "All (active)"],
            ["open", "Open"],
            ["acknowledged", "Acknowledged"],
            ["resolved", "Resolved"],
          ]}
          onChange={(v) => applyFilters({ ...filters, status: v as ExceptionFilters["status"], page: 1 })}
        />
        <FilterSelect
          label="Type"
          value={filters.type ?? "all"}
          options={[["all", "All"], ...Object.entries(EXCEPTION_TYPE_LABEL).map(([k, v]) => [k, v] as [string, string])]}
          onChange={(v) => applyFilters({ ...filters, type: v as ExceptionFilters["type"], page: 1 })}
        />
        <FilterSelect
          label="Assignment"
          value={filters.assignment ?? "all"}
          options={[
            ["all", "All"],
            ["mine", "Mine"],
            ["unassigned", "Unassigned"],
          ]}
          onChange={(v) => applyFilters({ ...filters, assignment: v as ExceptionFilters["assignment"], page: 1 })}
        />
        <input
          type="search"
          placeholder="Search load, truck, driver, carrier..."
          defaultValue={filters.q}
          onChange={(e) => applyFilters({ ...filters, q: e.target.value, page: 1 })}
          className="h-8 w-56 rounded-sm border border-desktop-border bg-background px-2 text-[12.5px]"
        />
        {/* Phase 2P.7 -- Section C: escalated-only quick filter. */}
        <label className="flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border px-2 text-[12.5px] text-desktop-text">
          <input type="checkbox" checked={filters.escalatedOnly ?? false} onChange={(e) => applyFilters({ ...filters, escalatedOnly: e.target.checked, page: 1 })} className="size-3.5" />
          Escalated only
        </label>
        <button type="button" onClick={clearFilters} className="ml-auto flex items-center gap-1 text-[12px] text-muted-foreground hover:text-desktop-text">
          <RotateCcw className="size-3" /> Clear Filters
        </button>
      </div>

      <div className={cn("overflow-x-auto rounded-md border border-desktop-border bg-card", isPending && "opacity-60")}>
        <table className="w-full text-[12.5px]">
          <thead>
            <tr className="border-b border-desktop-border text-left text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
              {["Severity", "Exception", "Load", "Truck", "Driver", "Age", "Owner", "Status"].map((h) => (
                <th key={h} className="px-3 py-2">
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {displayRows.map((row) => (
              <tr key={row.id} onClick={() => setOpenExceptionId(row.id)} className="cursor-pointer border-b border-desktop-border last:border-0 hover:bg-desktop-muted/40">
                <td className="px-3 py-2">
                  <span className="flex items-center gap-1">
                    <span className={cn("inline-flex items-center rounded-sm border px-1.5 py-0.5 text-[10.5px] font-bold uppercase", SEVERITY_TONE[row.severity])}>{SEVERITY_LABEL[row.severity]}</span>
                    {/* Phase 2P.7 -- text label, not color alone (a shrunk
                        icon paired with visible text next to it). */}
                    {row.escalated && (
                      <span className="inline-flex items-center gap-0.5 rounded-sm bg-danger/15 px-1 py-0.5 text-[10px] font-bold uppercase text-danger" title="Escalated">
                        <AlertTriangle className="size-3 shrink-0" /> Esc.
                      </span>
                    )}
                  </span>
                </td>
                <td className="px-3 py-2 font-medium text-desktop-text">{compoundTitle(row)}</td>
                <td className="px-3 py-2">{row.loadNumber ?? "--"}</td>
                <td className="px-3 py-2">{row.truckUnit ?? "--"}</td>
                <td className="px-3 py-2">{row.driverName ?? "--"}</td>
                <td className="px-3 py-2 tabular-nums">{formatAge(row.firstDetectedAt)}</td>
                <td className="px-3 py-2">{row.assignedToName ?? <span className="text-muted-foreground">Unassigned</span>}</td>
                <td className="px-3 py-2">
                  <span className={cn("inline-flex items-center rounded-sm px-1.5 py-0.5 text-[10.5px] font-semibold uppercase", STATUS_TONE[row.status])}>{row.status}</span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {displayRows.length === 0 && (
          <div className="p-6">
            <EmptyState title={emptyStateTitle} description={emptyStateDescription} />
          </div>
        )}
      </div>

      {data.total > data.pageSize && (
        <div className="flex items-center justify-between text-[12px] text-muted-foreground">
          <span>
            Page {data.page} of {Math.ceil(data.total / data.pageSize)} ({data.total} total)
          </span>
          <div className="flex gap-2">
            <button
              type="button"
              disabled={data.page <= 1}
              onClick={() => applyFilters({ ...filters, page: data.page - 1 })}
              className="rounded-sm border border-desktop-border px-2 py-1 disabled:opacity-40"
            >
              Previous
            </button>
            <button
              type="button"
              disabled={data.page >= Math.ceil(data.total / data.pageSize)}
              onClick={() => applyFilters({ ...filters, page: data.page + 1 })}
              className="rounded-sm border border-desktop-border px-2 py-1 disabled:opacity-40"
            >
              Next
            </button>
          </div>
        </div>
      )}

      {openExceptionId && (
        <ExceptionDrawer
          exceptionId={openExceptionId}
          onClose={() => setOpenExceptionId(null)}
          onSelectSibling={(id) => setOpenExceptionId(id)}
          onChanged={() => {
            router.refresh();
            applyFilters(filters);
          }}
        />
      )}
    </div>
  );
}

function FilterSelect({ label, value, options, onChange }: { label: string; value: string; options: [string, string][]; onChange: (v: string) => void }) {
  return (
    <label className="flex items-center gap-1.5 text-[12px] text-muted-foreground">
      {label}
      <select value={value} onChange={(e) => onChange(e.target.value)} className="h-8 rounded-sm border border-desktop-border bg-background px-1.5 text-[12.5px] text-desktop-text">
        {options.map(([v, l]) => (
          <option key={v} value={v}>
            {l}
          </option>
        ))}
      </select>
    </label>
  );
}
