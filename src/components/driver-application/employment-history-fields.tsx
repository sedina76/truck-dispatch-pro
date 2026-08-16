"use client";

import { Plus, Trash2 } from "lucide-react";

export type EmploymentHistoryEntry = {
  employer: string;
  position: string;
  start_date: string;
  end_date: string;
  reason_for_leaving: string;
};

const EMPTY_ENTRY: EmploymentHistoryEntry = {
  employer: "",
  position: "",
  start_date: "",
  end_date: "",
  reason_for_leaving: "",
};

const inputClass =
  "h-10 w-full rounded-lg border border-border bg-card px-3.5 text-sm shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20";

export function EmploymentHistoryFields({
  entries,
  onChange,
}: {
  entries: EmploymentHistoryEntry[];
  onChange: (entries: EmploymentHistoryEntry[]) => void;
}) {
  function updateEntry(index: number, field: keyof EmploymentHistoryEntry, value: string) {
    onChange(entries.map((entry, i) => (i === index ? { ...entry, [field]: value } : entry)));
  }

  function removeEntry(index: number) {
    onChange(entries.filter((_, i) => i !== index));
  }

  return (
    <div className="space-y-4 sm:col-span-2">
      {entries.map((entry, i) => (
        <div key={i} className="space-y-3 rounded-lg border border-border bg-card/50 p-4">
          <div className="flex items-center justify-between">
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
              Employer {i + 1}
            </p>
            {entries.length > 1 && (
              <button
                type="button"
                onClick={() => removeEntry(i)}
                className="flex items-center gap-1 text-xs font-medium text-danger hover:underline"
              >
                <Trash2 className="size-3.5" /> Remove
              </button>
            )}
          </div>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <input
              placeholder="Employer name"
              value={entry.employer}
              onChange={(e) => updateEntry(i, "employer", e.target.value)}
              className={inputClass}
            />
            <input
              placeholder="Position held"
              value={entry.position}
              onChange={(e) => updateEntry(i, "position", e.target.value)}
              className={inputClass}
            />
            <input
              type="date"
              aria-label="Start date"
              value={entry.start_date}
              onChange={(e) => updateEntry(i, "start_date", e.target.value)}
              className={inputClass}
            />
            <input
              type="date"
              aria-label="End date"
              value={entry.end_date}
              onChange={(e) => updateEntry(i, "end_date", e.target.value)}
              className={inputClass}
            />
            <input
              placeholder="Reason for leaving"
              value={entry.reason_for_leaving}
              onChange={(e) => updateEntry(i, "reason_for_leaving", e.target.value)}
              className={`${inputClass} sm:col-span-2`}
            />
          </div>
        </div>
      ))}
      <button
        type="button"
        onClick={() => onChange([...entries, { ...EMPTY_ENTRY }])}
        className="flex items-center gap-1.5 text-sm font-medium text-primary hover:underline"
      >
        <Plus className="size-4" /> Add another employer
      </button>
    </div>
  );
}

export { EMPTY_ENTRY };
