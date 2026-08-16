"use client";

import { createContext, useContext, useEffect, useMemo, useState } from "react";

// Shared "what can the toolbar do on THIS page" registry. Server Component
// pages can't use hooks, so each page renders a tiny <RegisterDesktopActions
// .../> client component with its own already-fetched, RLS-scoped data --
// that's the whole registration mechanism. DesktopToolbar (a sibling in the
// (app) layout) reads the same context to render real Print/Export/Email
// actions instead of one fixed global behavior.

export type DesktopExportOption = {
  label: string;
  /** A real GET route that streams the file -- never client-only fake data. */
  href: string;
};

export type DesktopEmailConfig = {
  /** Matches a case in /api/email/resolve and /api/email/send. */
  entityType: "invoice" | "statement" | "carrier_settlement" | "driver_settlement" | "payment";
  entityId: string;
};

export type DesktopPageActions = {
  /** Human label used in the Export menu's disabled tooltip context, etc. */
  title: string;
  /** Navigates to an existing dedicated print/PDF route in a new tab. */
  printHref?: string;
  /** If true and printHref is unset, the Print button calls window.print() on the current page. */
  printInPlace?: boolean;
  exportOptions?: DesktopExportOption[];
  exportDisabledReason?: string;
  email?: DesktopEmailConfig;
  emailDisabledReason?: string;
};

type Ctx = {
  actions: DesktopPageActions | null;
  setActions: (a: DesktopPageActions | null) => void;
};

const ActionsContext = createContext<Ctx | null>(null);

export function DesktopActionsProvider({ children }: { children: React.ReactNode }) {
  const [actions, setActions] = useState<DesktopPageActions | null>(null);
  const value = useMemo(() => ({ actions, setActions }), [actions]);
  return <ActionsContext.Provider value={value}>{children}</ActionsContext.Provider>;
}

export function useDesktopActions(): Ctx {
  const ctx = useContext(ActionsContext);
  if (!ctx) throw new Error("useDesktopActions must be used within DesktopActionsProvider");
  return ctx;
}

// A page renders this once with its resolved config. Registers on mount,
// clears on unmount/navigation-away so the next page's toolbar never
// inherits a stale action pointing at the wrong entity.
export function RegisterDesktopActions(props: DesktopPageActions) {
  const { setActions } = useDesktopActions();
  // Depend on a stable serialization, not the object identity, since Server
  // Component parents re-create this props object on every render.
  const key = JSON.stringify(props);
  useEffect(() => {
    setActions(props);
    return () => setActions(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return null;
}
