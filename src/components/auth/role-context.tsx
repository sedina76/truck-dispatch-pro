"use client";

import { createContext, useContext } from "react";

// The signed-in user's organization role, provided once by (app)/layout so
// client menus (top menu, billing tabs, Cmd-K search) can hide destinations
// the role cannot use. UX only -- every page is still guarded server-side.
const RoleContext = createContext<string | null>(null);

export function RoleProvider({ role, children }: { role: string | null; children: React.ReactNode }) {
  return <RoleContext.Provider value={role}>{children}</RoleContext.Provider>;
}

export function useOrgRole(): string | null {
  return useContext(RoleContext);
}
