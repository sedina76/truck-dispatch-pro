// Schedule calendar: every pickup / delivery appointment, maintenance due
// date and compliance expiration on one calendar. Pure -- the page reads the
// rows; this decides each item's status/color and which day it falls on.

export type CalendarStatus =
  | "done" // departed the stop
  | "on_site" // arrived, not departed
  | "late" // projected late, or the appointment passed without arrival
  | "at_risk"
  | "on_time"
  | "scheduled" // dispatched, nothing to say yet
  | "not_dispatched" // load has no driver/truck yet
  | "due" // maintenance due / compliance expiring
  | "overdue"; // maintenance past due / compliance expired

export type CalendarItem = {
  id: string;
  kind: "pickup" | "delivery" | "maintenance" | "compliance";
  day: string; // YYYY-MM-DD in the calendar's time zone
  at: string | null; // ISO instant for timed appointments
  allDay: boolean; // date-only appointment, maintenance, compliance
  timeLabel: string; // "8:00 AM MT", "8:00-2:00 PM MT", "No time set", ""
  title: string; // "LD-000001 pickup"
  subtitle: string; // "4BS -- West Valley City, UT"
  href: string;
  status: CalendarStatus;
};

export const STATUS_LABEL: Record<CalendarStatus, string> = {
  done: "Done",
  on_site: "On site",
  late: "Late",
  at_risk: "At risk",
  on_time: "On time",
  scheduled: "Scheduled",
  not_dispatched: "Not dispatched",
  due: "Due",
  overdue: "Overdue",
};

/** "2026-10-04" for an instant, in a time zone. */
export function dayKey(iso: string, timeZone: string): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(iso));
}

function addDays(day: string, n: number): string {
  const d = new Date(`${day}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/** The days shown: a Monday-to-Sunday week containing `day`, or just that day. */
export function visibleDays(day: string, view: "week" | "day"): string[] {
  if (view === "day") return [day];
  const dow = new Date(`${day}T12:00:00Z`).getUTCDay(); // 0 = Sunday
  const monday = addDays(day, dow === 0 ? -6 : 1 - dow);
  return Array.from({ length: 7 }, (_, i) => addDays(monday, i));
}

export function shiftDay(day: string, view: "week" | "day", dir: 1 | -1): string {
  return addDays(day, view === "week" ? 7 * dir : dir);
}

export function validDay(v: string | undefined, fallback: string): string {
  return v && /^\d{4}-\d{2}-\d{2}$/.test(v) && !Number.isNaN(Date.parse(`${v}T12:00:00Z`)) ? v : fallback;
}

/** Status of a stop appointment on the calendar. */
export function stopStatus(p: {
  scheduledAt: string;
  windowEnd: string | null;
  arrivedAt: string | null;
  departedAt: string | null;
  dispatched: boolean;
  routeRisk: string | null; // risk_status when this stop is the truck's current target
  dateOnly: boolean;
  now: number;
  timeZone: string;
}): CalendarStatus {
  if (p.departedAt) return "done";
  if (p.arrivedAt) return "on_site";
  if (p.routeRisk === "late") return "late";
  if (p.routeRisk === "at_risk") return "at_risk";
  // passed without an arrival: a timed appointment once its window closes;
  // a date-only one once that day is over
  const deadline = p.dateOnly ? null : Date.parse(p.windowEnd ?? p.scheduledAt);
  const passed = p.dateOnly ? dayKey(p.scheduledAt, p.timeZone) < dayKey(new Date(p.now).toISOString(), p.timeZone) : deadline != null && deadline < p.now;
  if (passed) return "late";
  if (!p.dispatched) return "not_dispatched";
  if (p.routeRisk === "on_time") return "on_time";
  return "scheduled";
}

/** Maintenance due / compliance expiry: overdue once the date has passed. */
export function dueStatus(day: string, today: string): CalendarStatus {
  return day < today ? "overdue" : "due";
}

export function groupByDay(items: CalendarItem[], days: string[]): Map<string, CalendarItem[]> {
  const m = new Map(days.map((d) => [d, [] as CalendarItem[]]));
  for (const it of items) m.get(it.day)?.push(it);
  for (const list of m.values())
    list.sort((a, b) => Number(b.allDay) - Number(a.allDay) || (a.at ?? "").localeCompare(b.at ?? "") || a.title.localeCompare(b.title));
  return m;
}
