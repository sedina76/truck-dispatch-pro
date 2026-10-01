// Pure decision logic for the "new message" chime, shared by the staff
// app (driver -> dispatch messages) and the Driver Portal (dispatch ->
// driver messages). Kept free of browser APIs so it's unit-testable.
//
// The watcher keeps a "baseline": the newest unread message timestamp it
// has already accounted for. The FIRST check after a page load only sets
// the baseline -- old unread messages never chime on every page load or
// navigation. After that, a newer unread message chimes exactly once.

export type UnreadSnapshot = { count: number; latestAt: string | null };

export type AlertDecision = { chime: boolean; baseline: string | null };

export function decideMessageAlert(baseline: string | null | undefined, snapshot: UnreadSnapshot): AlertDecision {
  const latest = snapshot.count > 0 ? snapshot.latestAt : null;
  // undefined = no check has run yet in this page session: set baseline only.
  if (baseline === undefined) return { chime: false, baseline: latest ?? null };
  if (!latest) return { chime: false, baseline };
  if (!baseline || Date.parse(latest) > Date.parse(baseline)) return { chime: true, baseline: latest };
  return { chime: false, baseline };
}

export const MESSAGE_SOUND_STORAGE_KEY = "tdp.messageSound";

// Default ON; only an explicit "off" mutes. Unreadable storage (private
// mode, blocked site data) also means ON.
export function soundEnabledFromStorage(value: string | null | undefined): boolean {
  return value !== "off";
}
