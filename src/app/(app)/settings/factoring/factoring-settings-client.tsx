"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Star, Plus, ChevronDown, ChevronRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmptyState } from "@/components/ui/empty-state";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter, DialogClose } from "@/components/ui/dialog";
import type { OrgRole } from "@/lib/auth/require-role";
import type { CarrierFactoringMode, CarrierFactoringReadiness, CarrierOption, FactoringCompanyRow, FactoringRelationshipRow } from "@/lib/factoring/types";
import { FEE_TIMING_OPTIONS, RECOURSE_TYPE_OPTIONS, deriveEffectiveState } from "@/lib/factoring/types";
import {
  createFactoringCompany,
  updateFactoringCompany,
  setFactoringCompanyActive,
  deleteFactoringCompany,
  createFactoringRelationship,
  updateFactoringRelationship,
  setDefaultFactoringRelationship,
  setFactoringRelationshipActive,
  setCarrierFactoringPolicy,
  type FactoringActionResult,
} from "./actions";

const inputCls = "h-8 w-full rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20";
const labelCls = "flex flex-col gap-1 text-xs font-medium text-muted-foreground";

// Same pattern as email-settings-client.tsx's useAction(): run a typed
// -result action, surface its error inline, refresh on success. Expected
// business errors (validation, "cannot delete", "cannot deactivate the
// default", a structured RPC rejection mapped by actions.ts) always come
// back as { ok: false, error } and are shown right here -- never thrown
// into the route boundary / generic error page.
function useAction() {
  const router = useRouter();
  const [pendingKey, setPendingKey] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function run(key: string, fn: () => Promise<FactoringActionResult>) {
    setPendingKey(key);
    setError(null);
    const result = await fn();
    setPendingKey(null);
    if (!result.ok) {
      setError(result.error);
      return false;
    }
    router.refresh();
    return true;
  }

  return { run, pendingKey, error, setError };
}

function fmtPct(n: number) {
  return `${Number(n).toFixed(2).replace(/\.00$/, "").replace(/(\.\d)0$/, "$1")}%`;
}

export function FactoringSettingsClient({
  companies,
  relationships,
  carriers,
  carrierScopingApplied,
  readinessByCarrierId,
  carrierUpdatedAtById,
  currentRole,
}: {
  companies: FactoringCompanyRow[];
  relationships: FactoringRelationshipRow[];
  carriers: CarrierOption[];
  carrierScopingApplied: boolean;
  readinessByCarrierId: Record<string, CarrierFactoringReadiness>;
  carrierUpdatedAtById: Record<string, string>;
  currentRole: OrgRole;
}) {
  // Phase 3B.1.4 (Section A/H): "unauthorized mutation buttons are not
  // shown." Purely a display convenience -- every action below
  // independently re-derives and re-checks the caller's real role/RLS
  // regardless of what these booleans say; hiding a button here can never
  // be the actual security boundary.
  const canManage = currentRole === "owner" || currentRole === "admin"; // create/delete company or relationship, set default, change policy
  const canEdit = canManage || currentRole === "accountant"; // ordinary relationship terms + is_active

  const [addCompanyOpen, setAddCompanyOpen] = useState(false);
  const [editCompany, setEditCompany] = useState<FactoringCompanyRow | null>(null);
  const [manageCompany, setManageCompany] = useState<FactoringCompanyRow | null>(null);
  const [editRelationship, setEditRelationship] = useState<FactoringRelationshipRow | null>(null);

  const companyById = new Map(companies.map((c) => [c.id, c]));
  const carrierById = new Map(carriers.map((c) => [c.id, c]));
  const relationshipsByCompany = new Map<string, FactoringRelationshipRow[]>();
  for (const r of relationships) {
    const list = relationshipsByCompany.get(r.factoring_company_id) ?? [];
    list.push(r);
    relationshipsByCompany.set(r.factoring_company_id, list);
  }

  return (
    <div className="space-y-6">
      <CarrierFactoringPolicyPanel
        carriers={carriers}
        relationships={relationships}
        companyById={companyById}
        carrierScopingApplied={carrierScopingApplied}
        readinessByCarrierId={readinessByCarrierId}
        carrierUpdatedAtById={carrierUpdatedAtById}
        canManage={canManage}
      />

      <div className="space-y-3">
        <div className="flex items-center justify-between">
          <div>
            <p className="text-sm font-semibold">Factoring Companies</p>
            <p className="text-xs text-muted-foreground">The factors your organization sells invoices to, and the commercial terms agreed with each, per carrier.</p>
          </div>
          {canManage && (
            <Button type="button" size="sm" onClick={() => setAddCompanyOpen(true)}>
              <Plus className="size-3.5" />
              Add Factoring Company
            </Button>
          )}
        </div>

        {companies.length === 0 ? (
          <div className="space-y-3">
            <EmptyState
              title="No factoring companies configured"
              description={canManage ? "Add your factoring company and default terms before submitting invoices for factoring." : "No factoring companies have been configured yet. An owner or admin can add one."}
            />
            {canManage && (
              <div className="flex justify-center">
                <Button type="button" size="sm" onClick={() => setAddCompanyOpen(true)}>
                  <Plus className="size-3.5" />
                  Add Factoring Company
                </Button>
              </div>
            )}
          </div>
        ) : (
          <div className="overflow-x-auto rounded-md border border-desktop-border bg-card shadow-elevation-1">
            <table className="w-full text-[13px]">
              <thead>
                <tr className="border-b border-desktop-border bg-desktop-header text-left text-[11px] font-semibold uppercase tracking-wide text-desktop-header-text">
                  <th className="px-3 py-2">Company</th>
                  <th className="px-3 py-2">Contact</th>
                  <th className="px-3 py-2">Relationships</th>
                  <th className="px-3 py-2">Status</th>
                  <th className="px-3 py-2 text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                {companies.map((company) => (
                  <CompanyTableRow
                    key={company.id}
                    company={company}
                    relationshipCount={relationshipsByCompany.get(company.id)?.length ?? 0}
                    onEdit={() => setEditCompany(company)}
                    onManage={() => setManageCompany(company)}
                    canManage={canManage}
                  />
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {addCompanyOpen && <CompanyFormDialog mode="create" onClose={() => setAddCompanyOpen(false)} />}
      {editCompany && <CompanyFormDialog mode="edit" company={editCompany} onClose={() => setEditCompany(null)} />}
      {manageCompany && (
        <ManageRelationshipsDialog
          company={manageCompany}
          relationships={relationshipsByCompany.get(manageCompany.id) ?? []}
          carriers={carriers}
          carrierById={carrierById}
          onClose={() => setManageCompany(null)}
          onEditRelationship={(r) => setEditRelationship(r)}
          canManage={canManage}
          canEdit={canEdit}
        />
      )}
      {editRelationship && (
        <RelationshipFormDialog
          mode="edit"
          companyId={editRelationship.factoring_company_id}
          companyName={companyById.get(editRelationship.factoring_company_id)?.name ?? ""}
          relationship={editRelationship}
          carriers={carriers}
          carrierById={carrierById}
          onClose={() => setEditRelationship(null)}
        />
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Carrier Factoring Policy panel (Phase 3B.1.3, Section F) -- replaces the
// old single org-wide "Default Factor" card. Every carrier's policy
// (unconfigured/direct/factored), classifier readiness, and resolved
// default relationship are shown per carrier -- never one org-wide
// summary, since 0138 made the default itself carrier-scoped. Only
// active carriers change policy; inactive ones are shown collapsed,
// historical, and never offered a Change Policy control.
// ---------------------------------------------------------------------------
function CarrierFactoringPolicyPanel({
  carriers,
  relationships,
  companyById,
  carrierScopingApplied,
  readinessByCarrierId,
  carrierUpdatedAtById,
  canManage,
}: {
  carriers: CarrierOption[];
  relationships: FactoringRelationshipRow[];
  companyById: Map<string, FactoringCompanyRow>;
  carrierScopingApplied: boolean;
  readinessByCarrierId: Record<string, CarrierFactoringReadiness>;
  carrierUpdatedAtById: Record<string, string>;
  canManage: boolean;
}) {
  const [showInactive, setShowInactive] = useState(false);
  const [policyCarrier, setPolicyCarrier] = useState<CarrierOption | null>(null);

  const activeCarriers = carriers.filter((c) => c.is_active);
  const inactiveCarriers = carriers.filter((c) => !c.is_active);
  const shown = showInactive ? carriers : activeCarriers;

  return (
    <div className="rounded-md border border-desktop-border bg-card shadow-elevation-1">
      <div className="flex h-7 items-center justify-between rounded-t-md bg-desktop-header px-3 text-[11px] font-semibold uppercase tracking-wide text-desktop-header-text">
        <span>Carrier Factoring Policy</span>
      </div>
      <div className="p-4">
        {!carrierScopingApplied ? (
          <p className="text-sm text-muted-foreground">Carrier-specific factoring policy is not available yet. This section will appear once the database migration is applied.</p>
        ) : carriers.length === 0 ? (
          <p className="text-sm text-muted-foreground">No carriers yet. Add a carrier before configuring factoring policy.</p>
        ) : (
          <div className="space-y-2">
            <p className="text-xs text-muted-foreground">
              Every carrier starts <span className="font-medium text-foreground">Unconfigured</span> and blocks invoice issuance until an owner or admin explicitly sets Direct or Factored.
            </p>
            <div className="overflow-x-auto rounded-md border border-desktop-border">
              <table className="w-full text-[13px]">
                <thead>
                  <tr className="border-b border-desktop-border bg-desktop-header text-left text-[11px] font-semibold uppercase tracking-wide text-desktop-header-text">
                    <th className="px-3 py-2">Carrier</th>
                    <th className="px-3 py-2">Policy</th>
                    <th className="px-3 py-2">Readiness</th>
                    <th className="px-3 py-2">Default Factor</th>
                    <th className="px-3 py-2 text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {shown.map((carrier) => {
                    const readiness = readinessByCarrierId[carrier.id];
                    const defaultRel = relationships.find((r) => r.carrier_id === carrier.id && r.is_default && r.is_active) ?? null;
                    const defaultCompany = defaultRel ? companyById.get(defaultRel.factoring_company_id) : null;
                    return (
                      <tr key={carrier.id} className="border-b border-desktop-border last:border-0">
                        <td className="px-3 py-2 font-medium">
                          {carrier.legal_name}
                          {!carrier.is_active && <span className="ml-1.5 text-[11px] font-normal text-muted-foreground">(Historical)</span>}
                        </td>
                        <td className="px-3 py-2">
                          <StatusBadge status={carrier.factoring_mode ?? "unconfigured"} />
                        </td>
                        <td className="px-3 py-2">{readiness ? <StatusBadge status={readiness.classification} /> : <span className="text-xs text-muted-foreground">--</span>}</td>
                        <td className="px-3 py-2 text-xs text-muted-foreground">
                          {defaultCompany ? (
                            <span className="text-foreground">
                              {defaultCompany.name}
                              {defaultRel?.relationship_name ? ` · ${defaultRel.relationship_name}` : ""}
                            </span>
                          ) : (
                            "Not set"
                          )}
                        </td>
                        <td className="px-3 py-2 text-right">
                          {canManage && carrier.is_active && (
                            <Button type="button" size="sm" variant="outline" onClick={() => setPolicyCarrier(carrier)}>
                              Change Policy
                            </Button>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            {inactiveCarriers.length > 0 && (
              <button type="button" className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground" onClick={() => setShowInactive((v) => !v)}>
                {showInactive ? <ChevronDown className="size-3.5" /> : <ChevronRight className="size-3.5" />}
                {showInactive ? "Hide" : "Show"} {inactiveCarriers.length} historical (inactive) carrier{inactiveCarriers.length === 1 ? "" : "s"}
              </button>
            )}
          </div>
        )}
      </div>
      {policyCarrier && (
        <ChangeCarrierPolicyDialog carrier={policyCarrier} expectedUpdatedAt={carrierUpdatedAtById[policyCarrier.id] ?? ""} onClose={() => setPolicyCarrier(null)} />
      )}
    </div>
  );
}

function ChangeCarrierPolicyDialog({ carrier, expectedUpdatedAt, onClose }: { carrier: CarrierOption; expectedUpdatedAt: string; onClose: () => void }) {
  const { run, pendingKey, error } = useAction();

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Change Factoring Policy &mdash; {carrier.legal_name}</DialogTitle>
          <DialogDescription>
            Currently <span className="font-medium text-foreground">{carrier.factoring_mode ?? "unconfigured"}</span>. Choosing Factored requires this carrier to already have a complete, ready default
            factoring relationship configured below -- owner/admin only, and a reason is required for every change.
          </DialogDescription>
        </DialogHeader>
        <form
          onSubmit={async (e) => {
            e.preventDefault();
            const fd = new FormData(e.currentTarget);
            const mode = String(fd.get("mode") ?? "") as CarrierFactoringMode;
            const reason = String(fd.get("reason") ?? "");
            const ok = await run("save", () => setCarrierFactoringPolicy(carrier.id, mode, reason, expectedUpdatedAt));
            if (ok) onClose();
          }}
          className="space-y-3"
        >
          <label className={labelCls}>
            New Policy <span className="text-danger">*</span>
            <select name="mode" defaultValue={carrier.factoring_mode === "factored" ? "factored" : "direct"} required className={inputCls}>
              <option value="direct">Direct &mdash; this carrier is paid directly</option>
              <option value="factored">Factored &mdash; invoices for this carrier are sold to a factor</option>
            </select>
          </label>
          <label className={labelCls}>
            Reason <span className="text-danger">*</span>
            <textarea
              name="reason"
              required
              rows={2}
              placeholder="Why is this carrier's factoring policy changing?"
              className="w-full rounded-md border border-border bg-card px-2 py-1.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
            />
          </label>
          {error && <p className="text-xs text-danger">{error}</p>}
          <DialogFooter>
            <DialogClose asChild>
              <Button type="button" variant="outline" onClick={onClose}>
                Cancel
              </Button>
            </DialogClose>
            <Button type="submit" disabled={pendingKey === "save"}>
              {pendingKey === "save" ? <Loader2 className="size-3.5 animate-spin" /> : null}
              Save
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

// ---------------------------------------------------------------------------
// Companies table row
// ---------------------------------------------------------------------------
function CompanyTableRow({
  company,
  relationshipCount,
  onEdit,
  onManage,
  canManage,
}: {
  company: FactoringCompanyRow;
  relationshipCount: number;
  onEdit: () => void;
  onManage: () => void;
  canManage: boolean;
}) {
  const { run, pendingKey, error } = useAction();
  const [confirmDelete, setConfirmDelete] = useState(false);

  return (
    <>
      <tr className="border-b border-desktop-border last:border-0 hover:bg-muted/30">
        <td className="px-3 py-2 font-medium">{company.name}</td>
        <td className="px-3 py-2 text-muted-foreground">{company.contact_name ?? company.email ?? company.phone ?? "--"}</td>
        <td className="px-3 py-2">
          <button type="button" onClick={onManage} className="text-primary hover:underline">
            {relationshipCount} {relationshipCount === 1 ? "relationship" : "relationships"}
          </button>
        </td>
        <td className="px-3 py-2">
          <StatusBadge status={company.is_active ? "active" : "inactive"} />
        </td>
        <td className="px-3 py-2">
          <div className="flex items-center justify-end gap-1.5">
            {canManage && (
              <Button type="button" size="sm" variant="outline" onClick={onEdit}>
                Edit
              </Button>
            )}
            <Button type="button" size="sm" variant="outline" disabled={pendingKey === "manage"} onClick={onManage}>
              {canManage ? "Manage" : "View"}
            </Button>
            {canManage && (
              <Button
                type="button"
                size="sm"
                variant="outline"
                disabled={pendingKey === "toggle-active"}
                onClick={() => run("toggle-active", () => setFactoringCompanyActive(company.id, !company.is_active))}
              >
                {pendingKey === "toggle-active" ? <Loader2 className="size-3.5 animate-spin" /> : null}
                {company.is_active ? "Deactivate" : "Reactivate"}
              </Button>
            )}
            {canManage && (
              <Button type="button" size="sm" variant="danger" disabled={pendingKey === "delete"} onClick={() => setConfirmDelete(true)}>
                Delete
              </Button>
            )}
          </div>
        </td>
      </tr>
      {(error || confirmDelete) && (
        <tr className="border-b border-desktop-border last:border-0">
          <td colSpan={5} className="px-3 pb-2">
            {confirmDelete && (
              <div className="flex items-center gap-2 rounded-md border border-danger/30 bg-danger/5 px-3 py-2 text-xs">
                <span>Delete {company.name}? This cannot be undone.</span>
                <Button
                  type="button"
                  size="sm"
                  variant="danger"
                  disabled={pendingKey === "delete"}
                  onClick={async () => {
                    const ok = await run("delete", () => deleteFactoringCompany(company.id));
                    if (ok) setConfirmDelete(false);
                  }}
                >
                  {pendingKey === "delete" ? <Loader2 className="size-3.5 animate-spin" /> : null}
                  Confirm Delete
                </Button>
                <Button type="button" size="sm" variant="outline" onClick={() => setConfirmDelete(false)}>
                  Cancel
                </Button>
              </div>
            )}
            {error && <p className="mt-1 text-xs text-danger">{error}</p>}
          </td>
        </tr>
      )}
    </>
  );
}

// ---------------------------------------------------------------------------
// Add/Edit company dialog
// ---------------------------------------------------------------------------
function CompanyFormDialog({ mode, company, onClose }: { mode: "create" | "edit"; company?: FactoringCompanyRow; onClose: () => void }) {
  const { run, pendingKey, error } = useAction();

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-xl">
        <DialogHeader>
          <DialogTitle>{mode === "create" ? "Add Factoring Company" : `Edit ${company?.name}`}</DialogTitle>
          <DialogDescription>The factor&apos;s identity and contact information.</DialogDescription>
        </DialogHeader>
        <form
          onSubmit={async (e) => {
            e.preventDefault();
            const fd = new FormData(e.currentTarget);
            const ok = mode === "create" ? await run("save", () => createFactoringCompany(fd)) : await run("save", () => updateFactoringCompany(company!.id, fd));
            if (ok) onClose();
          }}
          className="space-y-3"
        >
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <label className={labelCls}>
              Name <span className="text-danger">*</span>
              <input name="name" defaultValue={company?.name} required className={inputCls} />
            </label>
            <label className={labelCls}>
              Legal Name
              <input name="legal_name" defaultValue={company?.legal_name ?? ""} className={inputCls} />
            </label>
            <label className={labelCls}>
              Contact Name
              <input name="contact_name" defaultValue={company?.contact_name ?? ""} className={inputCls} />
            </label>
            <label className={labelCls}>
              Account / Reference Number
              <input name="account_number" defaultValue={company?.account_number ?? ""} className={inputCls} />
            </label>
            <label className={labelCls}>
              Email
              <input name="email" type="email" defaultValue={company?.email ?? ""} className={inputCls} />
            </label>
            <label className={labelCls}>
              Phone
              <input name="phone" type="tel" defaultValue={company?.phone ?? ""} className={inputCls} />
            </label>
            <label className={labelCls}>
              Website
              <input name="website" defaultValue={company?.website ?? ""} placeholder="https://" className={inputCls} />
            </label>
            <label className={labelCls}>
              Address
              <input name="address_line1" defaultValue={company?.address_line1 ?? ""} className={inputCls} />
            </label>
            <label className={labelCls}>
              City
              <input name="city" defaultValue={company?.city ?? ""} className={inputCls} />
            </label>
            <label className={labelCls}>
              State
              <input name="state" defaultValue={company?.state ?? ""} className={inputCls} />
            </label>
            <label className={labelCls}>
              Postal Code
              <input name="postal_code" defaultValue={company?.postal_code ?? ""} className={inputCls} />
            </label>
          </div>
          <label className={labelCls}>
            Notes
            <textarea name="notes" defaultValue={company?.notes ?? ""} rows={2} className="w-full rounded-md border border-border bg-card px-2 py-1.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20" />
          </label>
          {error && <p className="text-xs text-danger">{error}</p>}
          <DialogFooter>
            <DialogClose asChild>
              <Button type="button" variant="outline" onClick={onClose}>
                Cancel
              </Button>
            </DialogClose>
            <Button type="submit" disabled={pendingKey === "save"}>
              {pendingKey === "save" ? <Loader2 className="size-3.5 animate-spin" /> : null}
              Save
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

// ---------------------------------------------------------------------------
// Manage relationships dialog (per company) -- Phase 3B.1.3: each
// relationship's carrier is shown as its own immutable label; relationships
// can also be understood per-carrier via the Carrier Factoring Policy
// panel above (grouped/filterable by carrier, Section F).
// ---------------------------------------------------------------------------
function ManageRelationshipsDialog({
  company,
  relationships,
  carriers,
  carrierById,
  onClose,
  onEditRelationship,
  canManage,
  canEdit,
}: {
  company: FactoringCompanyRow;
  relationships: FactoringRelationshipRow[];
  carriers: CarrierOption[];
  carrierById: Map<string, CarrierOption>;
  onClose: () => void;
  onEditRelationship: (r: FactoringRelationshipRow) => void;
  canManage: boolean;
  canEdit: boolean;
}) {
  const [addOpen, setAddOpen] = useState(false);
  const activeCarriers = carriers.filter((c) => c.is_active);

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-3xl">
        <DialogHeader>
          <DialogTitle>{company.name} &mdash; Relationships</DialogTitle>
          <DialogDescription>Commercial terms agreed with this factor, per carrier. Editing a relationship&apos;s terms only affects future submissions -- already-submitted invoices keep the terms in effect when they were submitted.</DialogDescription>
        </DialogHeader>

        <div className="space-y-2">
          {canManage && (
            <div className="flex justify-end">
              <Button type="button" size="sm" disabled={activeCarriers.length === 0} onClick={() => setAddOpen(true)}>
                <Plus className="size-3.5" />
                Add Relationship
              </Button>
            </div>
          )}
          {canManage && activeCarriers.length === 0 && <p className="text-xs text-muted-foreground">Add an active carrier before creating a factoring relationship.</p>}

          {relationships.length === 0 ? (
            <p className="rounded-md border border-dashed border-desktop-border p-4 text-center text-sm text-muted-foreground">No relationships yet for this factor.</p>
          ) : (
            <div className="space-y-2">
              {relationships.map((r) => (
                <RelationshipCard
                  key={r.id}
                  relationship={r}
                  carrier={carrierById.get(r.carrier_id) ?? null}
                  onEdit={() => onEditRelationship(r)}
                  canManage={canManage}
                  canEdit={canEdit}
                />
              ))}
            </div>
          )}
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>
            Close
          </Button>
        </DialogFooter>

        {addOpen && (
          <RelationshipFormDialog mode="create" companyId={company.id} companyName={company.name} carriers={activeCarriers} carrierById={carrierById} onClose={() => setAddOpen(false)} />
        )}
      </DialogContent>
    </Dialog>
  );
}

function RelationshipCard({
  relationship,
  carrier,
  onEdit,
  canManage,
  canEdit,
}: {
  relationship: FactoringRelationshipRow;
  carrier: CarrierOption | null;
  onEdit: () => void;
  canManage: boolean;
  canEdit: boolean;
}) {
  const { run, pendingKey, error } = useAction();
  const state = deriveEffectiveState(relationship);
  const feeTimingLabel = FEE_TIMING_OPTIONS.find((o) => o.value === relationship.fee_timing)?.label ?? relationship.fee_timing;
  const recourseLabel = RECOURSE_TYPE_OPTIONS.find((o) => o.value === relationship.recourse_type)?.label ?? relationship.recourse_type;

  return (
    <div className="rounded-md border border-desktop-border p-3">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <p className="flex flex-wrap items-center gap-1.5 text-xs font-medium text-muted-foreground">
            Carrier: <span className="text-foreground">{carrier?.legal_name ?? "Unknown carrier"}</span>
            {carrier && !carrier.is_active && <span className="text-[11px] font-normal">(Historical)</span>}
          </p>
          <p className="text-sm font-medium">
            {relationship.relationship_name || "Unnamed Relationship"}
            {relationship.is_default && (
              <span className="ml-1.5 inline-flex items-center gap-0.5 text-xs font-normal text-primary">
                <Star className="size-3 fill-current" /> Default
              </span>
            )}
          </p>
          <div className="mt-1 flex flex-wrap gap-x-4 gap-y-0.5 text-xs text-muted-foreground">
            <span>Advance: <span className="text-foreground">{fmtPct(relationship.default_advance_percentage)}</span></span>
            <span>Fee: <span className="text-foreground">{fmtPct(relationship.default_factoring_fee_percentage)}</span></span>
            <span>Reserve: <span className="text-foreground">{fmtPct(relationship.default_reserve_percentage)}</span></span>
            <span>{feeTimingLabel}</span>
            <span>{recourseLabel}</span>
          </div>
          <div className="mt-1 flex items-center gap-2 text-xs text-muted-foreground">
            <StatusBadge status={state} />
            <span>
              Effective {relationship.effective_from}
              {relationship.effective_to ? ` – ${relationship.effective_to}` : " (open-ended)"}
            </span>
          </div>
        </div>
        <div className="flex flex-wrap items-center gap-1.5">
          {canEdit && (
            <Button type="button" size="sm" variant="outline" onClick={onEdit}>
              Edit
            </Button>
          )}
          {canManage && relationship.is_active && !relationship.is_default && (
            <Button type="button" size="sm" variant="outline" disabled={pendingKey === "default"} onClick={() => run("default", () => setDefaultFactoringRelationship(relationship.id))}>
              {pendingKey === "default" ? <Loader2 className="size-3.5 animate-spin" /> : null}
              Set Default
            </Button>
          )}
          {canEdit && (
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={pendingKey === "toggle-active"}
              onClick={() => run("toggle-active", () => setFactoringRelationshipActive(relationship.id, !relationship.is_active))}
            >
              {pendingKey === "toggle-active" ? <Loader2 className="size-3.5 animate-spin" /> : null}
              {relationship.is_active ? "Deactivate" : "Reactivate"}
            </Button>
          )}
        </div>
      </div>
      {error && <p className="mt-2 text-xs text-danger">{error}</p>}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Add/Edit relationship dialog -- Phase 3B.1.3 (Section B/F): carrier is
// the FIRST field a user chooses when creating (active carriers only,
// Section B.3); once created, the carrier is shown as a locked, immutable
// label (Section B.9/F) -- there is no control anywhere in this dialog
// that can move a relationship to a different carrier.
// ---------------------------------------------------------------------------
function RelationshipFormDialog({
  mode,
  companyId,
  companyName,
  relationship,
  carriers,
  carrierById,
  onClose,
}: {
  mode: "create" | "edit";
  companyId: string;
  companyName: string;
  relationship?: FactoringRelationshipRow;
  carriers: CarrierOption[]; // active carriers only, for the create-mode selector
  carrierById: Map<string, CarrierOption>; // all carriers (incl. inactive), for the locked edit-mode label
  onClose: () => void;
}) {
  const { run, pendingKey, error, setError } = useAction();
  const [carrierId, setCarrierId] = useState("");
  const lockedCarrier = relationship ? carrierById.get(relationship.carrier_id) : null;

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>{mode === "create" ? "Add Factoring Relationship" : "Edit Factoring Relationship"}</DialogTitle>
          <DialogDescription>
            For {companyName}. Percentages are entered as whole percentage points (e.g. 95 for 95%), not decimals.
          </DialogDescription>
        </DialogHeader>
        <form
          onSubmit={async (e) => {
            e.preventDefault();
            if (mode === "create" && !carrierId) {
              setError("A carrier is required.");
              return;
            }
            const fd = new FormData(e.currentTarget);
            const ok =
              mode === "create" ? await run("save", () => createFactoringRelationship(carrierId, companyId, fd)) : await run("save", () => updateFactoringRelationship(relationship!.id, fd));
            if (ok) onClose();
          }}
          className="max-h-[70vh] space-y-3 overflow-y-auto pr-1"
        >
          {mode === "create" ? (
            <label className={labelCls}>
              Carrier <span className="text-danger">*</span>
              <select value={carrierId} onChange={(e) => setCarrierId(e.target.value)} required className={inputCls}>
                <option value="" disabled>
                  Select a carrier&hellip;
                </option>
                {carriers.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.legal_name}
                  </option>
                ))}
              </select>
            </label>
          ) : (
            <label className={labelCls}>
              Carrier
              <div className="flex h-8 items-center justify-between rounded-md border border-border bg-muted/40 px-2 text-sm text-foreground">
                <span>{lockedCarrier?.legal_name ?? "Unknown carrier"}</span>
                <span className="text-[11px] font-medium text-muted-foreground">Locked</span>
              </div>
              <span className="text-[11px] font-normal text-muted-foreground">
                A relationship&apos;s carrier cannot be changed after creation. To move this factor to a different carrier, create a new relationship.
              </span>
            </label>
          )}

          <label className={labelCls}>
            Relationship Name
            <input name="relationship_name" defaultValue={relationship?.relationship_name ?? ""} placeholder="e.g. Standard Recourse" className={inputCls} />
          </label>

          <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
            <label className={labelCls}>
              Advance % <span className="text-danger">*</span>
              <input name="default_advance_percentage" type="number" min={0} max={100} step="0.01" defaultValue={relationship?.default_advance_percentage ?? 95} required className={inputCls} />
            </label>
            <label className={labelCls}>
              Factoring Fee % <span className="text-danger">*</span>
              <input name="default_factoring_fee_percentage" type="number" min={0} max={100} step="0.01" defaultValue={relationship?.default_factoring_fee_percentage ?? 2} required className={inputCls} />
            </label>
            <label className={labelCls}>
              Reserve % <span className="text-danger">*</span>
              <input name="default_reserve_percentage" type="number" min={0} max={100} step="0.01" defaultValue={relationship?.default_reserve_percentage ?? 5} required className={inputCls} />
            </label>
          </div>

          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <label className={labelCls}>
              Fee Timing <span className="text-danger">*</span>
              <select name="fee_timing" defaultValue={relationship?.fee_timing ?? "deducted_at_funding"} className={inputCls}>
                {FEE_TIMING_OPTIONS.map((o) => (
                  <option key={o.value} value={o.value}>
                    {o.label}
                  </option>
                ))}
              </select>
            </label>
            <label className={labelCls}>
              Recourse Type <span className="text-danger">*</span>
              <select name="recourse_type" defaultValue={relationship?.recourse_type ?? "recourse"} className={inputCls}>
                {RECOURSE_TYPE_OPTIONS.map((o) => (
                  <option key={o.value} value={o.value}>
                    {o.label}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <p className="text-xs text-muted-foreground">
            {FEE_TIMING_OPTIONS.find((o) => o.value === (relationship?.fee_timing ?? "deducted_at_funding"))?.description}
            {" "}
            {RECOURSE_TYPE_OPTIONS.find((o) => o.value === (relationship?.recourse_type ?? "recourse"))?.description}
          </p>

          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <label className={labelCls}>
              Payment Terms (days)
              <input name="payment_terms_days" type="number" min={0} step="1" defaultValue={relationship?.payment_terms_days ?? ""} className={inputCls} />
            </label>
            <label className={labelCls}>
              Minimum Fee ($)
              <input name="minimum_fee" type="number" min={0} step="0.01" defaultValue={relationship?.minimum_fee ?? ""} className={inputCls} />
            </label>
            <label className={labelCls}>
              Wire Fee ($)
              <input name="wire_fee" type="number" min={0} step="0.01" defaultValue={relationship?.wire_fee ?? ""} className={inputCls} />
            </label>
            <label className={labelCls}>
              ACH Fee ($)
              <input name="ach_fee" type="number" min={0} step="0.01" defaultValue={relationship?.ach_fee ?? ""} className={inputCls} />
            </label>
            <label className={labelCls}>
              Other Default Fee ($)
              <input name="other_fee_default" type="number" min={0} step="0.01" defaultValue={relationship?.other_fee_default ?? ""} className={inputCls} />
            </label>
          </div>

          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <label className={labelCls}>
              Effective From
              <input name="effective_from" type="date" defaultValue={relationship?.effective_from ?? new Date().toISOString().slice(0, 10)} className={inputCls} />
            </label>
            <label className={labelCls}>
              Effective To (optional)
              <input name="effective_to" type="date" defaultValue={relationship?.effective_to ?? ""} className={inputCls} />
            </label>
          </div>

          {error && <p className="text-xs text-danger">{error}</p>}
          <DialogFooter>
            <DialogClose asChild>
              <Button type="button" variant="outline" onClick={onClose}>
                Cancel
              </Button>
            </DialogClose>
            <Button type="submit" disabled={pendingKey === "save"}>
              {pendingKey === "save" ? <Loader2 className="size-3.5 animate-spin" /> : null}
              Save
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
