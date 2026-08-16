"use client";

import { useEffect } from "react";
import { FormTextarea } from "@/components/ui/form-field";
import { useDispatchFormState } from "./dispatch-form-state";

// Same fix as AssignmentFields (spec section 7/9/10): React 19 resets a
// form's own uncontrolled fields to their original mount-time default
// right after a form-action submission completes, which would otherwise
// silently clear whatever internal note the user typed right before a
// conflict. Re-applied via effect after that reset, using exactly what was
// just submitted (DispatchActionState.values), not the page's original
// load-time default.
export function DispatchNotesField({ defaultValue }: { defaultValue?: string | null }) {
  const state = useDispatchFormState();
  const v = state.values;

  useEffect(() => {
    if (!v) return;
    const el = document.getElementById("notes") as HTMLTextAreaElement | null;
    if (el) el.value = v.notes;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state]);

  return <FormTextarea label="Notes" name="notes" defaultValue={v?.notes || defaultValue || ""} />;
}
