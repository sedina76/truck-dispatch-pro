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

// Inverse of the display helpers above: given a stored UTC instant and the
// stop's own timezone, returns the "YYYY-MM-DD"/"HH:mm" (24-hour) strings
// an edit form's <input type="date">/<input type="time"> need to pre-fill
// with the CORRECT local wall-clock values -- never a raw ISO-string slice
// of the UTC instant, which silently shows the wrong calendar date/time
// whenever the stop's local day differs from the UTC day (e.g. an 11:00 PM
// Pacific appointment is already the next day in UTC). Round-trips
// correctly back through zonedDateTimeToUtc().
export function stopLocalDateInputValue(iso: string | null, timezone: string | null): string {
  if (!iso) return "";
  const tz = timezone ?? "UTC";
  try {
    const parts = new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date(iso));
    const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
    return `${get("year")}-${get("month")}-${get("day")}`;
  } catch {
    return iso.slice(0, 10);
  }
}

export function stopLocalTimeInputValue(iso: string | null, timezone: string | null): string {
  if (!iso) return "";
  const tz = timezone ?? "UTC";
  try {
    const parts = new Intl.DateTimeFormat("en-US", { timeZone: tz, hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(new Date(iso));
    const hour = parts.find((p) => p.type === "hour")?.value ?? "00";
    const minute = parts.find((p) => p.type === "minute")?.value ?? "00";
    return `${hour === "24" ? "00" : hour}:${minute}`;
  } catch {
    return "";
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
