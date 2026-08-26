"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { ShieldAlert, ShieldCheck, ShieldOff, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { StatusBadge } from "@/components/ui/status-badge";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { useToast } from "@/components/ui/toast";
import { W9StatusCard } from "@/components/carrier-w9/status-card";
import type { CarrierW9Row } from "@/lib/carrier-w9/types";
import {
  ENFORCEMENT_MODE_DESCRIPTIONS,
  ENFORCEMENT_MODE_LABELS,
  groupRequirements,
  type CarrierComplianceReadiness,
} from "@/lib/carrier-compliance/types";
import {
  createCarrierComplianceOverrideAction,
  liftCarrierSuspensionAction,
  revokeCarrierComplianceOverrideAction,
  suspendCarrierAction,
} from "@/app/(app)/carriers/[id]/compliance-actions";

type Role = "owner" | "admin" | "dispatcher" | "accountant" | "driver" | "viewer";

const REASON_LABELS: Record<string, string> = {
  MISSING: "Missing",
  EXPIRED: "Expired",
  UNVERIFIED: "Unverified",
  EXPIRING_SOON: "Expiring soon",
};

export function ComplianceTab({
  carrierId,
  role,
  readiness,
  readinessError,
  suspension,
  w9Embed,
}: {
  carrierId: string;
  role: Role;
  readiness: CarrierComplianceReadiness | null;
  readinessError: string | null;
  suspension: { reason: string; suspended_at: string; suspended_by_name: string | null } | null;
  w9Embed: { w9: CarrierW9Row | null; w9LoadError: string | null; applicationId: string; organizationId: string } | null;
}) {
  const router = useRouter();
  const toast = useToast();
  const canManageSuspension = role === "owner" || role === "admin";
  const canOverride = role === "owner" || role === "admin";

  const [suspendOpen, setSuspendOpen] = useState(false);
  const [suspendReason, setSuspendReason] = useState("");
  const [suspendPending, startSuspend] = useTransition();

  const [liftOpen, setLiftOpen] = useState(false);
  const [liftReason, setLiftReason] = useState("");
  const [liftPending, startLift] = useTransition();

  const [overrideKey, setOverrideKey] = useState<string | null>(null);
  const [overrideReason, setOverrideReason] = useState("");
  const [overrideExpires, setOverrideExpires] = useState("");
  const [overridePending, startOverride] = useTransition();

  const [revokePending, startRevoke] = useTransition();

  // A failed readiness call must never be silently reported as READY.
  if (!readiness) {
    return (
      <div className="rounded-md border border-danger/30 bg-danger/5 p-4 text-[13px] text-danger">
        Compliance status could not be loaded{readinessError ? `: ${readinessError}` : "."} This does not mean the
        carrier is ready to dispatch -- try reloading the page.
      </div>
    );
  }

  const blockingCount = readiness.blocking_reasons.length;
  const warningCount = readiness.warnings.length;
  const satisfiedCount = readiness.requirements.filter((r) => r.status === "VALID").length;
  const groups = groupRequirements(readiness.requirements);

  function handleSuspend() {
    if (!suspendReason.trim()) { toast.show("error", "A suspension reason is required."); return; }
    startSuspend(async () => {
      const result = await suspendCarrierAction(carrierId, suspendReason.trim());
      if (!result.ok) { toast.show("error", result.error); return; }
      setSuspendOpen(false);
      setSuspendReason("");
      toast.show("success", "Carrier suspended.");
      router.refresh();
    });
  }

  function handleLift() {
    startLift(async () => {
      const result = await liftCarrierSuspensionAction(carrierId, liftReason.trim());
      if (!result.ok) { toast.show("error", result.error); return; }
      setLiftOpen(false);
      setLiftReason("");
      toast.show("success", "Suspension lifted.");
      router.refresh();
    });
  }

  function handleOverride() {
    if (!overrideKey) return;
    if (!overrideReason.trim()) { toast.show("error", "An override reason is required."); return; }
    startOverride(async () => {
      const result = await createCarrierComplianceOverrideAction(
        carrierId,
        overrideKey,
        overrideReason.trim(),
        overrideExpires ? new Date(overrideExpires).toISOString() : null
      );
      if (!result.ok) { toast.show("error", result.error); return; }
      setOverrideKey(null);
      setOverrideReason("");
      setOverrideExpires("");
      toast.show("success", "Override created.");
      router.refresh();
    });
  }

  function handleRevoke(requirementKey: string) {
    const reason = prompt("Reason for revoking this override?")?.trim();
    if (!reason) return;
    startRevoke(async () => {
      const result = await revokeCarrierComplianceOverrideAction(carrierId, requirementKey, reason);
      if (!result.ok) { toast.show("error", result.error); return; }
      toast.show("success", "Override revoked.");
      router.refresh();
    });
  }

  return (
    <div className="min-w-0 space-y-4">
      {/* Overall readiness header */}
      <div className="min-w-0 rounded-md border border-desktop-border bg-card p-4">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0">
            <p className="text-[14px] font-semibold text-desktop-text">Carrier Compliance</p>
            <p className="mt-0.5 text-[12.5px] text-muted-foreground">Overall dispatch-readiness, computed by the compliance engine.</p>
          </div>
          <div className="shrink-0">
            <StatusBadge status={readiness.status} />
          </div>
        </div>

        <div className="mt-3 grid grid-cols-1 gap-2 text-[12.5px] sm:grid-cols-3">
          <div className="rounded-sm bg-danger/5 px-2.5 py-1.5"><span className="font-semibold text-danger">{blockingCount}</span> Blocking</div>
          <div className="rounded-sm bg-warning/5 px-2.5 py-1.5"><span className="font-semibold text-desktop-warning">{warningCount}</span> Warning</div>
          <div className="rounded-sm bg-success/5 px-2.5 py-1.5"><span className="font-semibold text-desktop-success">{satisfiedCount}</span> Satisfied</div>
        </div>

        <div className="mt-3 border-t border-desktop-border pt-3">
          <p className="text-[12.5px] font-medium text-desktop-text">
            Enforcement: <span className="font-semibold">{ENFORCEMENT_MODE_LABELS[readiness.enforcement_mode]}</span>
          </p>
          <p className="mt-0.5 text-[12px] text-muted-foreground">{ENFORCEMENT_MODE_DESCRIPTIONS[readiness.enforcement_mode]}</p>
          {readiness.status === "NOT_READY" && readiness.enforcement_mode !== "enforced" && (
            <p className="mt-1 text-[12px] text-muted-foreground">This carrier is not currently blocked from dispatch.</p>
          )}
        </div>
      </div>

      {/* Suspension panel */}
      {readiness.status === "SUSPENDED" && (
        <div className="min-w-0 rounded-md border border-danger/30 bg-danger/5 p-4">
          <div className="flex flex-wrap items-center gap-2">
            <ShieldOff className="size-4 shrink-0 text-danger" aria-hidden="true" />
            <p className="text-[14px] font-semibold text-danger">Carrier Suspended</p>
          </div>
          {suspension && (
            <dl className="mt-2 grid grid-cols-1 gap-x-4 gap-y-1 text-[12.5px] sm:grid-cols-2">
              <div className="min-w-0"><dt className="text-muted-foreground">Reason</dt><dd className="wrap-break-word text-desktop-text">{suspension.reason}</dd></div>
              <div className="min-w-0"><dt className="text-muted-foreground">Suspended</dt><dd className="text-desktop-text">{new Date(suspension.suspended_at).toLocaleString()}{suspension.suspended_by_name ? ` by ${suspension.suspended_by_name}` : ""}</dd></div>
            </dl>
          )}
          {canManageSuspension && (
            <div className="mt-3">
              <Button type="button" size="sm" variant="outline" disabled={liftPending} onClick={() => setLiftOpen(true)}>
                {liftPending ? <Loader2 className="size-3.5 animate-spin" /> : <ShieldCheck className="size-3.5" />} Lift Suspension
              </Button>
            </div>
          )}
        </div>
      )}

      {readiness.status !== "SUSPENDED" && canManageSuspension && (
        <div className="flex justify-end">
          <Button type="button" size="sm" variant="danger" disabled={suspendPending} onClick={() => setSuspendOpen(true)}>
            {suspendPending ? <Loader2 className="size-3.5 animate-spin" /> : <ShieldOff className="size-3.5" />} Suspend Carrier
          </Button>
        </div>
      )}

      {/* Critical blocks */}
      {blockingCount > 0 && (
        <div className="min-w-0 rounded-md border border-danger/30 bg-danger/5 p-4">
          <p className="flex items-center gap-1.5 text-[13px] font-semibold text-danger"><ShieldAlert className="size-4 shrink-0" aria-hidden="true" /> Critical Blocks</p>
          <ul className="mt-2 space-y-1 text-[12.5px]">
            {readiness.blocking_reasons.map((b, i) => (
              <li key={`${b.requirement_key ?? "suspended"}-${i}`} className="min-w-0 wrap-break-word text-desktop-text">
                {b.display_name} &mdash; {REASON_LABELS[b.reason] ?? b.reason}
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* Warnings */}
      {warningCount > 0 && (
        <div className="min-w-0 rounded-md border border-warning/30 bg-warning/5 p-4">
          <p className="text-[13px] font-semibold text-desktop-warning">Warnings</p>
          <ul className="mt-2 space-y-1 text-[12.5px]">
            {readiness.warnings.map((w, i) => (
              <li key={`${w.requirement_key}-${i}`} className="min-w-0 wrap-break-word text-desktop-text">
                {w.display_name} &mdash; {REASON_LABELS[w.reason] ?? w.reason}
              </li>
            ))}
          </ul>
        </div>
      )}

      {readiness.status === "READY" && (
        <div className="rounded-md border border-desktop-border bg-card p-4 text-[13px] text-desktop-text">
          All dispatch-blocking carrier compliance requirements are currently satisfied.
        </div>
      )}

      {/* Requirements, grouped */}
      <div className="space-y-3">
        {groups.map((group) => (
          <div key={group.title} className="min-w-0 rounded-md border border-desktop-border bg-card p-4">
            <p className="text-[13px] font-semibold text-desktop-text">{group.title}</p>
            <ul className="mt-2 divide-y divide-desktop-border">
              {group.requirements.map((req) => (
                <li key={req.requirement_key} className="min-w-0 py-2">
                  <div className="flex min-w-0 flex-wrap items-center justify-between gap-2">
                    <div className="min-w-0">
                      <p className="wrap-break-word text-[13px] font-medium text-desktop-text">{req.display_name}</p>
                      <p className="text-[11.5px] capitalize text-muted-foreground">
                        {req.classification}
                        {req.verification_required ? " -- verification required" : ""}
                        {req.has_active_override ? " -- overridden" : ""}
                      </p>
                    </div>
                    <div className="flex shrink-0 flex-wrap items-center gap-2">
                      <StatusBadge status={req.status} />
                      {canOverride && req.overridable && req.status !== "VALID" && !req.has_active_override && (
                        <Button type="button" size="sm" variant="outline" onClick={() => setOverrideKey(req.requirement_key)}>
                          Override
                        </Button>
                      )}
                      {canOverride && req.has_active_override && (
                        <Button type="button" size="sm" variant="outline" disabled={revokePending} onClick={() => handleRevoke(req.requirement_key)}>
                          {revokePending ? <Loader2 className="size-3.5 animate-spin" /> : null} Revoke Override
                        </Button>
                      )}
                    </div>
                  </div>
                  {req.requirement_key === "w9" && w9Embed && (
                    <div className="mt-2">
                      {w9Embed.w9LoadError ? (
                        <div className="rounded-md border border-danger/30 bg-danger/5 p-3 text-[12.5px] text-danger">
                          W-9 status could not be loaded: {w9Embed.w9LoadError}. This does not mean no W-9 exists.
                        </div>
                      ) : (
                        <W9StatusCard w9={w9Embed.w9} applicationId={w9Embed.applicationId} organizationId={w9Embed.organizationId} role={role} pdfRouteBase={`/carriers/onboarding/${w9Embed.applicationId}/w9`} />
                      )}
                    </div>
                  )}
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>

      {/* Suspend dialog */}
      <Dialog open={suspendOpen} onOpenChange={setSuspendOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Suspend Carrier?</DialogTitle>
            <DialogDescription>This does not change the carrier&apos;s active/inactive status -- it only marks compliance readiness as SUSPENDED until lifted.</DialogDescription>
          </DialogHeader>
          <Input value={suspendReason} onChange={(e) => setSuspendReason(e.target.value)} placeholder="Reason for suspension (required)" className="h-8 text-[12.5px]" />
          <DialogFooter>
            <Button variant="outline" disabled={suspendPending} onClick={() => setSuspendOpen(false)}>Cancel</Button>
            <Button variant="danger" disabled={suspendPending} onClick={handleSuspend}>{suspendPending ? "Suspending…" : "Suspend Carrier"}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Lift dialog */}
      <Dialog open={liftOpen} onOpenChange={setLiftOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Lift Suspension?</DialogTitle>
            <DialogDescription>Readiness will revert to whatever the underlying requirements currently compute.</DialogDescription>
          </DialogHeader>
          <Input value={liftReason} onChange={(e) => setLiftReason(e.target.value)} placeholder="Reason for lifting (optional)" className="h-8 text-[12.5px]" />
          <DialogFooter>
            <Button variant="outline" disabled={liftPending} onClick={() => setLiftOpen(false)}>Cancel</Button>
            <Button variant="primary" disabled={liftPending} onClick={handleLift}>{liftPending ? "Lifting…" : "Lift Suspension"}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Override dialog */}
      <Dialog open={overrideKey !== null} onOpenChange={(open) => !open && setOverrideKey(null)}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Override Requirement?</DialogTitle>
            <DialogDescription>This does not change the underlying requirement -- it only stops this one requirement from blocking dispatch until revoked or expired.</DialogDescription>
          </DialogHeader>
          <div className="space-y-2">
            <Input value={overrideReason} onChange={(e) => setOverrideReason(e.target.value)} placeholder="Reason for override (required)" className="h-8 text-[12.5px]" />
            <label className="block text-[12px] text-muted-foreground">
              Expires (optional)
              <Input type="date" value={overrideExpires} onChange={(e) => setOverrideExpires(e.target.value)} className="mt-1 h-8 text-[12.5px]" />
            </label>
          </div>
          <DialogFooter>
            <Button variant="outline" disabled={overridePending} onClick={() => setOverrideKey(null)}>Cancel</Button>
            <Button variant="primary" disabled={overridePending} onClick={handleOverride}>{overridePending ? "Creating…" : "Create Override"}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
