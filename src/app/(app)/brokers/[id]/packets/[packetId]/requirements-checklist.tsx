"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Check, AlertTriangle } from "lucide-react";
import { setBrokerPacketRequirements } from "../actions";

// Phase 2M.2A repair -- one controlled checklist + one Save Requirements
// button, replacing 7 independent <form>s each with their own uncontrolled
// (defaultChecked) checkbox and Save button. See setBrokerPacketRequirements()'s
// own header comment for exactly why the old shape could persist correctly
// yet never visibly reflect it. Controlled state here means the checkbox
// always shows exactly what was last saved (or what's pending save) --
// never a stale defaultChecked snapshot from the initial render.
export function RequirementsChecklist({
  brokerId,
  documentTypes,
  documentLabels,
  initialRequired,
}: {
  brokerId: string;
  documentTypes: readonly string[];
  documentLabels: Record<string, string>;
  initialRequired: Record<string, boolean>;
}) {
  const router = useRouter();
  const [required, setRequired] = useState<Record<string, boolean>>(initialRequired);
  const [savedRequired, setSavedRequired] = useState<Record<string, boolean>>(initialRequired);
  const [saving, startSaving] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [justSaved, setJustSaved] = useState(false);

  const dirty = documentTypes.some((type) => Boolean(required[type]) !== Boolean(savedRequired[type]));

  function toggle(type: string) {
    setJustSaved(false);
    setRequired((prev) => ({ ...prev, [type]: !prev[type] }));
  }

  function handleSave() {
    setError(null);
    setJustSaved(false);
    startSaving(async () => {
      const payload = documentTypes.map((type) => ({ document_type: type, is_required: Boolean(required[type]) }));
      const result = await setBrokerPacketRequirements(brokerId, payload);
      if (!result.ok) {
        setError(result.error);
        return;
      }
      setSavedRequired(required);
      setJustSaved(true);
      // Available Documents/Selected Documents below derive their
      // "required" set from a fresh server read -- refresh so they agree
      // with what was just saved, without a full page reload.
      router.refresh();
    });
  }

  return (
    <div className="space-y-2">
      <div className="grid gap-2 sm:grid-cols-2">
        {documentTypes.map((type) => (
          <label key={type} className="flex items-center justify-between gap-2 rounded border px-2 py-1.5 text-sm">
            <span className="min-w-0 wrap-break-word">{documentLabels[type] ?? type}</span>
            <span className="flex shrink-0 items-center gap-1 text-xs">
              <input type="checkbox" checked={Boolean(required[type])} onChange={() => toggle(type)} disabled={saving} />
              Required
            </span>
          </label>
        ))}
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <button
          type="button"
          onClick={handleSave}
          disabled={saving || !dirty}
          className="flex h-8 items-center gap-1.5 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground disabled:opacity-40"
        >
          {saving ? <Loader2 className="size-3.5 animate-spin" /> : <Check className="size-3.5" />}
          Save Requirements
        </button>
        {!saving && justSaved && !dirty && <span className="text-xs text-success">Saved.</span>}
        {!saving && dirty && !error && <span className="text-xs text-muted-foreground">Unsaved changes.</span>}
        {error && (
          <span className="flex items-center gap-1 text-xs text-destructive">
            <AlertTriangle className="size-3.5 shrink-0" /> {error}
          </span>
        )}
      </div>
    </div>
  );
}
