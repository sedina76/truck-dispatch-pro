// Minimal expected-vs-unexpected error split for the Fuel Detail page's two
// most commonly double-clicked/edge-case-prone actions (Save Changes,
// Create Company Expense) -- spec "ERROR UX": a business-rule rejection
// (locked record, recoverable amount over the total, missing responsible
// driver, expense already recorded) is normal application feedback, never
// the full-screen Next.js Runtime Error overlay. Same minimal
// `{ error: string | null }` shape src/lib/supabase/actions.ts already uses
// for login/signup -- no need for the richer field-level/action-link state
// dispatch's conflict UX needed, since fuel's errors don't link to another
// record.
export type FuelActionState = { error: string | null };

export const FUEL_ACTION_INITIAL_STATE: FuelActionState = { error: null };

// fuel/actions.ts already has translateFuelError() for raw DB/trigger
// messages, and already throws plain, already-friendly Error objects for
// its own validation (fuelLogValues, "already recorded", etc.) -- both are
// "expected" in the sense that they're not a real bug, just business rules.
// Anything that ISN'T an Error instance at all (a real unexpected
// exception -- network/connection failure, etc.) is logged in full
// server-side and shown a generic message instead.
export function toFuelActionState(err: unknown): FuelActionState {
  if (err instanceof Error) return { error: err.message };
  console.error("[fuel] unexpected error:", err);
  return { error: "This action could not be completed. Please try again." };
}
