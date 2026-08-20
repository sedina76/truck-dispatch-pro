"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Star, Plus, Pencil } from "lucide-react";
import { Button } from "@/components/ui/button";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmptyState } from "@/components/ui/empty-state";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter, DialogClose } from "@/components/ui/dialog";
import type { FactoringCompanyRow, FactoringRelationshipRow } from "@/lib/factoring/types";
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
  type FactoringActionResult,
} from "./actions";

const inputCls = "h-8 w-full rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20";
const labelCls = "flex flex-col gap-1 text-xs font-medium text-muted-foreground";

// Same pattern as email-settings-client.tsx's useAction(): run a typed
// -result action, surface its error inline, refresh on success. Expected
// business errors (validation, "cannot delete", "cannot deactivate the
// default") always come back as { ok: false, error } and are shown right
// here -- never thrown into the route boundary / generic error page.
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

export function FactoringSettingsClient({ companies, relationships }: { companies: FactoringCompanyRow[]; relationships: FactoringRelationshipRow[] }) {
  const [addCompanyOpen, setAddCompanyOpen] = useState(false);
  const [editCompany, setEditCompany] = useState<FactoringCompanyRow | null>(null);
  const [manageCompany, setManageCompany] = useState<FactoringCompanyRow | null>(null);
  const [editRelationship, setEditRelationship] = useState<FactoringRelationshipRow | null>(null);

  const companyById = new Map(companies.map((c) => [c.id, c]));
  const relationshipsByCompany = new Map<string, FactoringRelationshipRow[]>();
  for (const r of relationships) {
    const list = relationshipsByCompany.get(r.factoring_company_id) ?? [];
    list.push(r);
    relationshipsByCompany.set(r.factoring_company_id, list);
  }

  const defaultRelationship = relationships.find((r) => r.is_default && r.is_active) ?? null;
  const defaultCompany = defaultRelationship ? (companyById.get(defaultRelationship.factoring_company_id) ?? null) : null;
  const hasAnyActiveRelationship = relationships.some((r) => r.is_active);

  return (
    <div className="space-y-6">
      <DefaultFactorCard
        company={defaultCompany}
        relationship={defaultRelationship}
        hasAnyActiveRelationship={hasAnyActiveRelationship}
        onEditTerms={() => defaultRelationship && setEditRelationship(defaultRelationship)}
      />

      <div className="space-y-3">
        <div className="flex items-center justify-between">
          <div>
            <p className="text-sm font-semibold">Factoring Companies</p>
            <p className="text-xs text-muted-foreground">The factors your organization sells invoices to, and the commercial terms agreed with each.</p>
          </div>
          <Button type="button" size="sm" onClick={() => setAddCompanyOpen(true)}>
            <Plus className="size-3.5" />
            Add Factoring Company
          </Button>
        </div>

        {companies.length === 0 ? (
          <div className="space-y-3">
            <EmptyState title="No factoring companies configured" description="Add your factoring company and default terms before submitting invoices for factoring." />
            <div className="flex justify-center">
              <Button type="button" size="sm" onClick={() => setAddCompanyOpen(true)}>
                <Plus className="size-3.5" />
                Add Factoring Company
              </Button>
            </div>
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
          onClose={() => setManageCompany(null)}
          onEditRelationship={(r) => setEditRelationship(r)}
        />
      )}
      {editRelationship && <RelationshipFormDialog mode="edit" companyId={editRelationship.factoring_company_id} relationship={editRelationship} onClose={() => setEditRelationship(null)} />}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Default Factor summary card
// ---------------------------------------------------------------------------
function DefaultFactorCard({
  company,
  relationship,
  hasAnyActiveRelationship,
  onEditTerms,
}: {
  company: FactoringCompanyRow | null;
  relationship: FactoringRelationshipRow | null;
  hasAnyActiveRelationship: boolean;
  onEditTerms: () => void;
}) {
  return (
    <div className="rounded-md border border-desktop-border bg-card shadow-elevation-1">
      <div className="flex h-7 items-center rounded-t-md bg-desktop-header px-3 text-[11px] font-semibold uppercase tracking-wide text-desktop-header-text">Default Factor</div>
      <div className="p-4">
        {!company || !relationship ? (
          <p className="text-sm text-muted-foreground">
            {hasAnyActiveRelationship
              ? "No default factoring relationship set. Open a company below and use Set Default on one of its relationships."
              : "No default factoring relationship configured. Add a factoring company and relationship below, then set it as default."}
          </p>
        ) : (
          <div className="flex flex-wrap items-start justify-between gap-4">
            <div className="space-y-1">
              <p className="text-sm font-semibold">
                {company.name}
                {relationship.relationship_name && <span className="font-normal text-muted-foreground"> &middot; {relationship.relationship_name}</span>}
              </p>
              <div className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted-foreground">
                <span>Advance: <span className="font-medium text-foreground">{fmtPct(relationship.default_advance_percentage)}</span></span>
                <span>Fee: <span className="font-medium text-foreground">{fmtPct(relationship.default_factoring_fee_percentage)}</span></span>
                <span>Reserve: <span className="font-medium text-foreground">{fmtPct(relationship.default_reserve_percentage)}</span></span>
                <span className="capitalize">{RECOURSE_TYPE_OPTIONS.find((o) => o.value === relationship.recourse_type)?.label}</span>
                <StatusBadge status="active" />
              </div>
            </div>
            <Button type="button" size="sm" variant="outline" onClick={onEditTerms}>
              <Pencil className="size-3.5" />
              Edit Terms
            </Button>
          </div>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Companies table row
// ---------------------------------------------------------------------------
function CompanyTableRow({ company, relationshipCount, onEdit, onManage }: { company: FactoringCompanyRow; relationshipCount: number; onEdit: () => void; onManage: () => void }) {
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
            <Button type="button" size="sm" variant="outline" onClick={onEdit}>
              Edit
            </Button>
            <Button type="button" size="sm" variant="outline" disabled={pendingKey === "manage"} onClick={onManage}>
              Manage
            </Button>
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
            <Button type="button" size="sm" variant="danger" disabled={pendingKey === "delete"} onClick={() => setConfirmDelete(true)}>
              Delete
            </Button>
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
// Manage relationships dialog (per company)
// ---------------------------------------------------------------------------
function ManageRelationshipsDialog({
  company,
  relationships,
  onClose,
  onEditRelationship,
}: {
  company: FactoringCompanyRow;
  relationships: FactoringRelationshipRow[];
  onClose: () => void;
  onEditRelationship: (r: FactoringRelationshipRow) => void;
}) {
  const [addOpen, setAddOpen] = useState(false);

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-3xl">
        <DialogHeader>
          <DialogTitle>{company.name} &mdash; Relationships</DialogTitle>
          <DialogDescription>Commercial terms agreed with this factor. Editing a relationship&apos;s terms only affects future submissions -- already-submitted invoices keep the terms in effect when they were submitted.</DialogDescription>
        </DialogHeader>

        <div className="space-y-2">
          <div className="flex justify-end">
            <Button type="button" size="sm" onClick={() => setAddOpen(true)}>
              <Plus className="size-3.5" />
              Add Relationship
            </Button>
          </div>

          {relationships.length === 0 ? (
            <p className="rounded-md border border-dashed border-desktop-border p-4 text-center text-sm text-muted-foreground">No relationships yet for this factor.</p>
          ) : (
            <div className="space-y-2">
              {relationships.map((r) => (
                <RelationshipCard key={r.id} relationship={r} onEdit={() => onEditRelationship(r)} />
              ))}
            </div>
          )}
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>
            Close
          </Button>
        </DialogFooter>

        {addOpen && <RelationshipFormDialog mode="create" companyId={company.id} onClose={() => setAddOpen(false)} />}
      </DialogContent>
    </Dialog>
  );
}

function RelationshipCard({ relationship, onEdit }: { relationship: FactoringRelationshipRow; onEdit: () => void }) {
  const { run, pendingKey, error } = useAction();
  const state = deriveEffectiveState(relationship);
  const feeTimingLabel = FEE_TIMING_OPTIONS.find((o) => o.value === relationship.fee_timing)?.label ?? relationship.fee_timing;
  const recourseLabel = RECOURSE_TYPE_OPTIONS.find((o) => o.value === relationship.recourse_type)?.label ?? relationship.recourse_type;

  return (
    <div className="rounded-md border border-desktop-border p-3">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
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
          <Button type="button" size="sm" variant="outline" onClick={onEdit}>
            Edit
          </Button>
          {relationship.is_active && !relationship.is_default && (
            <Button type="button" size="sm" variant="outline" disabled={pendingKey === "default"} onClick={() => run("default", () => setDefaultFactoringRelationship(relationship.id))}>
              {pendingKey === "default" ? <Loader2 className="size-3.5 animate-spin" /> : null}
              Set Default
            </Button>
          )}
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
        </div>
      </div>
      {error && <p className="mt-2 text-xs text-danger">{error}</p>}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Add/Edit relationship dialog
// ---------------------------------------------------------------------------
function RelationshipFormDialog({
  mode,
  companyId,
  relationship,
  onClose,
}: {
  mode: "create" | "edit";
  companyId: string;
  relationship?: FactoringRelationshipRow;
  onClose: () => void;
}) {
  const { run, pendingKey, error } = useAction();

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>{mode === "create" ? "Add Factoring Relationship" : "Edit Factoring Relationship"}</DialogTitle>
          <DialogDescription>Percentages are entered as whole percentage points (e.g. 95 for 95%), not decimals.</DialogDescription>
        </DialogHeader>
        <form
          onSubmit={async (e) => {
            e.preventDefault();
            const fd = new FormData(e.currentTarget);
            const ok = mode === "create" ? await run("save", () => createFactoringRelationship(companyId, fd)) : await run("save", () => updateFactoringRelationship(relationship!.id, fd));
            if (ok) onClose();
          }}
          className="max-h-[70vh] space-y-3 overflow-y-auto pr-1"
        >
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
