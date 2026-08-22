"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { ArrowUp, ArrowDown, Pencil, Trash2, Plus, Eye, EyeOff, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { StatusBadge } from "@/components/ui/status-badge";
import { useToast } from "@/components/ui/toast";
import { cn } from "@/lib/utils";
import {
  updateTemplateMeta,
  addClause,
  updateClause,
  deleteClause,
  reorderClauses,
  publishTemplate,
  retireTemplate,
  createNewVersion,
} from "../actions";

type Template = {
  id: string;
  template_key: string;
  version_number: number;
  name: string;
  description: string | null;
  status: string;
  is_required_for_onboarding: boolean;
  requires_signer_title: boolean;
  published_at: string | null;
};
type Clause = { id: string; clause_key: string; title: string; body: string; display_order: number; requires_initials: boolean };

function ClauseEditForm({ clause, templateId, onDone }: { clause: Clause | null; templateId: string; onDone: () => void }) {
  const toast = useToast();
  const [pending, startPending] = useTransition();
  const [title, setTitle] = useState(clause?.title ?? "");
  const [body, setBody] = useState(clause?.body ?? "");
  const [requiresInitials, setRequiresInitials] = useState(clause?.requires_initials ?? false);

  function handleSave() {
    const formData = new FormData();
    formData.set("title", title);
    formData.set("body", body);
    if (requiresInitials) formData.set("requires_initials", "on");
    startPending(async () => {
      const result = clause ? await updateClause(clause.id, templateId, formData) : await addClause(templateId, formData);
      if (!result.ok) toast.show("error", result.error);
      else {
        toast.show("success", clause ? "Clause updated." : "Clause added.");
        onDone();
      }
    });
  }

  return (
    <div className="rounded-sm border border-desktop-border bg-desktop-bg p-3">
      <div className="space-y-1">
        <label className="text-[12px] font-medium text-desktop-text">Title</label>
        <Input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Detention & Layover Policy" />
      </div>
      <div className="mt-2 space-y-1">
        <label className="text-[12px] font-medium text-desktop-text">Body</label>
        <textarea
          value={body}
          onChange={(e) => setBody(e.target.value)}
          rows={4}
          className="w-full rounded-sm border border-desktop-border bg-card px-2.5 py-2 text-[13px] shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
        />
      </div>
      <label className="mt-2 flex items-center gap-2 text-[13px] text-desktop-text">
        <input type="checkbox" checked={requiresInitials} onChange={(e) => setRequiresInitials(e.target.checked)} className="size-4 rounded-sm border-desktop-border" />
        Requires the carrier to initial this clause
      </label>
      <div className="mt-2.5 flex justify-end gap-2">
        <Button type="button" size="sm" variant="ghost" onClick={onDone} disabled={pending}>
          Cancel
        </Button>
        <Button type="button" size="sm" disabled={pending || !title.trim() || !body.trim()} onClick={handleSave}>
          {pending ? <Loader2 className="size-3.5 animate-spin" /> : clause ? "Save Clause" : "Add Clause"}
        </Button>
      </div>
    </div>
  );
}

export function TemplateEditor({ template, initialClauses, canManage }: { template: Template; initialClauses: Clause[]; canManage: boolean }) {
  const toast = useToast();
  const router = useRouter();
  const [addingClause, setAddingClause] = useState(false);
  const [previewMode, setPreviewMode] = useState(false);
  const [publishing, startPublish] = useTransition();
  const [retiring, startRetire] = useTransition();
  const [reordering, startReorder] = useTransition();
  const [creatingVersion, startCreateVersion] = useTransition();

  const isDraft = template.status === "draft";
  const clauses = [...initialClauses].sort((a, b) => a.display_order - b.display_order);

  function refresh() {
    router.refresh();
  }

  function handleReorder(fromIndex: number, direction: -1 | 1) {
    const toIndex = fromIndex + direction;
    if (toIndex < 0 || toIndex >= clauses.length) return;
    const reordered = [...clauses];
    const [moved] = reordered.splice(fromIndex, 1);
    reordered.splice(toIndex, 0, moved);
    startReorder(async () => {
      const result = await reorderClauses(template.id, reordered.map((c) => c.id));
      if (!result.ok) toast.show("error", result.error);
      else refresh();
    });
  }

  function handlePublish() {
    if (!confirm("Publish this template? Once published, its content becomes permanently locked -- future changes require creating a new version.")) return;
    startPublish(async () => {
      const result = await publishTemplate(template.id);
      if (!result.ok) toast.show("error", result.error);
      else {
        toast.show("success", "Template published.");
        refresh();
      }
    });
  }

  function handleRetire() {
    if (!confirm("Retire this template? It will no longer be assignable to new applications.")) return;
    startRetire(async () => {
      const result = await retireTemplate(template.id);
      if (!result.ok) toast.show("error", result.error);
      else {
        toast.show("success", "Template retired.");
        refresh();
      }
    });
  }

  function handleNewVersion() {
    startCreateVersion(async () => {
      await createNewVersion(template.id);
    });
  }

  return (
    <div className="space-y-3">
      <div className="rounded-md border border-desktop-border bg-card p-4">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-[15px] font-semibold text-desktop-text">{template.name}</h1>
              <StatusBadge status={template.status} />
            </div>
            <p className="mt-0.5 text-[12px] text-muted-foreground">
              {template.template_key} -- v{template.version_number}
              {template.is_required_for_onboarding && " -- Required for Onboarding"}
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <Button type="button" size="sm" variant="outline" onClick={() => setPreviewMode((p) => !p)}>
              {previewMode ? <EyeOff className="size-3.5" /> : <Eye className="size-3.5" />}
              {previewMode ? "Exit Preview" : "Preview"}
            </Button>
            {canManage && isDraft && (
              <Button type="button" size="sm" disabled={publishing || clauses.length === 0} onClick={handlePublish}>
                {publishing ? "Publishing..." : "Publish"}
              </Button>
            )}
            {canManage && template.status === "published" && (
              <Button type="button" size="sm" variant="danger" disabled={retiring} onClick={handleRetire}>
                {retiring ? "Retiring..." : "Retire"}
              </Button>
            )}
            {canManage && template.status !== "draft" && (
              <Button type="button" size="sm" variant="outline" disabled={creatingVersion} onClick={handleNewVersion}>
                {creatingVersion ? "Creating..." : "Create New Version"}
              </Button>
            )}
          </div>
        </div>

        {canManage && isDraft && !previewMode && <TemplateMetaForm template={template} onSaved={refresh} />}
        {(!isDraft || !canManage) && template.description && <p className="mt-3 text-[13px] text-muted-foreground">{template.description}</p>}
      </div>

      <div className="rounded-md border border-desktop-border bg-card p-4">
        <h2 className="text-[13.5px] font-semibold text-desktop-text">Clauses{previewMode && " -- Carrier Preview"}</h2>
        <div className={cn("mt-3 space-y-2", previewMode && "rounded-sm border border-desktop-border bg-desktop-bg p-3")}>
          {clauses.length === 0 && <p className="text-[13px] text-muted-foreground">No clauses yet.</p>}
          {previewMode
            ? clauses.map((c) => (
                <div key={c.id} className="rounded-sm border border-desktop-border bg-card p-3">
                  <p className="text-[13px] font-semibold text-desktop-text">{c.title}</p>
                  <p className="mt-1 whitespace-pre-wrap text-[12.5px] leading-relaxed text-muted-foreground">{c.body}</p>
                  {c.requires_initials && (
                    <div className="mt-2 flex items-center gap-2 text-[12px] text-muted-foreground">
                      Initials: <span className="inline-block h-7 w-16 rounded-sm border border-dashed border-desktop-border" />
                    </div>
                  )}
                </div>
              ))
            : clauses.map((c, i) => (
                <div key={c.id} className="flex items-start justify-between gap-2 rounded-sm border border-desktop-border p-3">
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      <p className="text-[13.5px] font-semibold text-desktop-text">{c.title}</p>
                      {c.requires_initials && <span className="rounded-sm bg-primary/10 px-1.5 py-0.5 text-[10px] font-semibold text-primary">Requires Initials</span>}
                    </div>
                    <p className="mt-1 whitespace-pre-wrap text-[12.5px] leading-relaxed text-muted-foreground">{c.body}</p>
                  </div>
                  {canManage && isDraft && (
                    <ClauseActions clause={c} templateId={template.id} index={i} count={clauses.length} onReorder={handleReorder} onChanged={refresh} reordering={reordering} />
                  )}
                </div>
              ))}
        </div>

        {canManage && isDraft && !previewMode && (
          <div className="mt-3">
            {addingClause ? (
              <ClauseEditForm clause={null} templateId={template.id} onDone={() => { setAddingClause(false); refresh(); }} />
            ) : (
              <Button type="button" size="sm" variant="outline" onClick={() => setAddingClause(true)}>
                <Plus className="size-3.5" /> Add Clause
              </Button>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

function ClauseActions({
  clause,
  templateId,
  index,
  count,
  onReorder,
  onChanged,
  reordering,
}: {
  clause: Clause;
  templateId: string;
  index: number;
  count: number;
  onReorder: (index: number, direction: -1 | 1) => void;
  onChanged: () => void;
  reordering: boolean;
}) {
  const toast = useToast();
  const [editing, setEditing] = useState(false);
  const [deleting, startDelete] = useTransition();

  if (editing) {
    return <ClauseEditForm clause={clause} templateId={templateId} onDone={() => { setEditing(false); onChanged(); }} />;
  }

  return (
    <div className="flex shrink-0 flex-col items-end gap-1">
      <div className="flex items-center gap-1">
        <Button type="button" size="icon" variant="ghost" disabled={index === 0 || reordering} onClick={() => onReorder(index, -1)} title="Move up">
          <ArrowUp className="size-3.5" />
        </Button>
        <Button type="button" size="icon" variant="ghost" disabled={index === count - 1 || reordering} onClick={() => onReorder(index, 1)} title="Move down">
          <ArrowDown className="size-3.5" />
        </Button>
      </div>
      <div className="flex items-center gap-1">
        <Button type="button" size="icon" variant="ghost" onClick={() => setEditing(true)} title="Edit">
          <Pencil className="size-3.5" />
        </Button>
        <Button
          type="button"
          size="icon"
          variant="ghost"
          disabled={deleting}
          onClick={() => {
            if (!confirm("Delete this clause?")) return;
            startDelete(async () => {
              const result = await deleteClause(clause.id, templateId);
              if (!result.ok) toast.show("error", result.error);
              else onChanged();
            });
          }}
          title="Delete"
        >
          <Trash2 className="size-3.5 text-danger" />
        </Button>
      </div>
    </div>
  );
}

function TemplateMetaForm({ template, onSaved }: { template: Template; onSaved: () => void }) {
  const toast = useToast();
  const [pending, startPending] = useTransition();

  function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const formData = new FormData(e.currentTarget);
    startPending(async () => {
      const result = await updateTemplateMeta(template.id, formData);
      if (!result.ok) toast.show("error", result.error);
      else {
        toast.show("success", "Saved.");
        onSaved();
      }
    });
  }

  return (
    <form onSubmit={handleSubmit} className="mt-3 space-y-2.5 border-t border-desktop-border pt-3">
      <div className="grid grid-cols-1 gap-2.5 sm:grid-cols-2">
        <div className="space-y-1">
          <label className="text-[12px] font-medium text-desktop-text">Name</label>
          <Input name="name" defaultValue={template.name} required />
        </div>
      </div>
      <div className="space-y-1">
        <label className="text-[12px] font-medium text-desktop-text">Description</label>
        <textarea
          name="description"
          defaultValue={template.description ?? ""}
          rows={2}
          className="w-full rounded-sm border border-desktop-border bg-card px-2.5 py-2 text-[13px] shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
        />
      </div>
      <div className="flex flex-wrap gap-4">
        <label className="flex items-center gap-2 text-[13px] text-desktop-text">
          <input type="checkbox" name="requires_signer_title" defaultChecked={template.requires_signer_title} className="size-4 rounded-sm border-desktop-border" />
          Require signer title
        </label>
        <label className="flex items-center gap-2 text-[13px] text-desktop-text">
          <input type="checkbox" name="is_required_for_onboarding" defaultChecked={template.is_required_for_onboarding} className="size-4 rounded-sm border-desktop-border" />
          Required for onboarding (blocks conversion until signed)
        </label>
      </div>
      <div className="flex justify-end">
        <Button type="submit" size="sm" disabled={pending}>
          {pending ? "Saving..." : "Save"}
        </Button>
      </div>
    </form>
  );
}
