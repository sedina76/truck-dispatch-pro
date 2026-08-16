// ---------------------------------------------------------------------------
// Centralized stop-appointment display (spec section 14): every surface
// (Board, Drawer, Live Tracking, Driver Portal, notifications, load sheet)
// formats through these two functions so they can never disagree about
// what timezone a stop's time is shown in. Safe/trivial side of the
// problem -- Intl.DateTimeFormat with an explicit timeZone is already
// correct by construction; the hard part (parsing local wall time back
// into UTC) lives in convert.ts.
// ---------------------------------------------------------------------------

// "ET"/"CT"/"MT"/"PT" for the zones that have them; the zone's own
// generic short name otherwise (e.g. "MST" for Arizona, which has no DST
// so "MT" would be misleading). UTC is special-cased -- Intl's own
// shortGeneric for UTC renders as "GMT+0", not "UTC".
export function shortZoneLabel(timezone: string, atIso?: string): string {
  if (timezone === "UTC") return "UTC";
  try {
    const fmt = new Intl.DateTimeFormat("en-US", { timeZone: timezone, timeZoneName: "shortGeneric" });
    const part = fmt.formatToParts(atIso ? new Date(atIso) : new Date()).find((p) => p.type === "timeZoneName");
    return part?.value ?? timezone;
  } catch {
    return timezone;
  }
}

export function formatStopDateTime(iso: string | null, timezone: string | null, opts?: { includeYear?: boolean; dateOnly?: boolean; timeOnly?: boolean }): string {
  if (!iso) return "--";
  const tz = timezone ?? "UTC";
  try {
    if (opts?.timeOnly) {
      const time = new Intl.DateTimeFormat("en-US", { timeZone: tz, hour: "numeric", minute: "2-digit" }).format(new Date(iso));
      return `${time} ${shortZoneLabel(tz, iso)}`;
    }
    const date = new Intl.DateTimeFormat("en-US", { timeZone: tz, month: "short", day: "numeric", year: opts?.includeYear ? "numeric" : undefined }).format(new Date(iso));
    if (opts?.dateOnly) return date;
    const time = new Intl.DateTimeFormat("en-US", { timeZone: tz, hour: "numeric", minute: "2-digit" }).format(new Date(iso));
    return `${date}, ${time} ${shortZoneLabel(tz, iso)}`;
  } catch {
    // Invalid/legacy timezone string that somehow made it into the DB --
    // degrade to a plain UTC-labeled render rather than throwing.
    return `${new Date(iso).toISOString()} UTC`;
  }
}

// Formats an appointment window using ONE zone for both ends (spec
// section 16: scheduled_at/scheduled_window_end always share a stop's
// timezone in this schema).
export function formatStopWindow(startIso: string | null, endIso: string | null, timezone: string | null): string {
  if (!startIso) return "--";
  if (!endIso) return formatStopDateTime(startIso, timezone);
  const tz = timezone ?? "UTC";
  const startTime = new Intl.DateTimeFormat("en-US", { timeZone: tz, hour: "numeric", minute: "2-digit" }).format(new Date(startIso));
  const endTime = new Intl.DateTimeFormat("en-US", { timeZone: tz, hour: "numeric", minute: "2-digit" }).format(new Date(endIso));
  const date = new Intl.DateTimeFormat("en-US", { timeZone: tz, month: "short", day: "numeric" }).format(new Date(startIso));
  return `${date}, ${startTime}–${endTime} ${shortZoneLabel(tz, startIso)}`;
}
