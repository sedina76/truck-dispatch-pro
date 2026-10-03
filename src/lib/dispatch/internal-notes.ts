// Dispatch internal (staff-only) notes live in public.dispatch_internal_notes
// (0067), one row per dispatch. 0069 dropped the old dispatches.notes column.

/** Appends one stamped line to the existing notes text (null/blank = none yet). */
export function appendNoteLine(existing: string | null, line: string): string {
  return existing && existing.trim() ? `${existing}\n${line}` : line;
}
