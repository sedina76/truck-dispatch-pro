"use client";

import { createContext, useContext } from "react";
import type { DispatchActionState } from "@/lib/dispatch/errors";

// Same standalone-context pattern as CollapsibleSectionsProvider
// (src/components/desktop/collapsible-section.tsx): the Server Component
// page renders <DispatchForm> around a deeply-nested JSX tree it also
// builds, and any client descendant (AssignmentFields, DispatchConflictAlert)
// reads the current action-result state without it being threaded through
// every layer of props in between.
const DispatchFormStateContext = createContext<DispatchActionState>({ error: null });

export function useDispatchFormState(): DispatchActionState {
  return useContext(DispatchFormStateContext);
}

export { DispatchFormStateContext };
