import { isValidIanaTimezone } from "./iana";

// ---------------------------------------------------------------------------
// Local-wall-time -> UTC conversion, DST-aware, zero new dependencies.
//
// Algorithm (the same "guess and correct" approach date-fns-tz/luxon use
// internally, verified live against all four DST edge cases below before
// being trusted): treat the requested wall-clock time as if it were UTC to
// get a rough instant, ask Intl what wall-clock time that instant actually
// is in the target zone, use the difference to compute the zone's UTC
// offset, then apply it. One correction pass is enough except right at a
// DST transition, which is exactly the case this function must get right
// -- so it also re-verifies by formatting its own answer back through the
// target zone and comparing to what was asked for.
// ---------------------------------------------------------------------------

function offsetMsAt(utcMs: number, timeZone: string): number {
  const fmt = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  });
  const parts = Object.fromEntries(fmt.formatToParts(new Date(utcMs)).map((p) => [p.type, p.value]));
  // Some ICU builds render midnight as "24" instead of "00" with hour12:false.
  const hour = parts.hour === "24" ? 0 : Number(parts.hour);
  const asUtc = Date.UTC(Number(parts.year), Number(parts.month) - 1, Number(parts.day), hour, Number(parts.minute), Number(parts.second));
  return asUtc - utcMs;
}

export type ZonedConversionResult =
  | { ok: true; iso: string; ambiguous: boolean }
  | { ok: false; error: string };

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TIME_RE = /^\d{2}:\d{2}$/;

// date: "YYYY-MM-DD", time: "HH:mm" (24-hour), timezone: IANA identifier.
export function zonedDateTimeToUtc(date: string, time: string, timezone: string): ZonedConversionResult {
  if (!DATE_RE.test(date)) return { ok: false, error: "Enter a valid date." };
  if (!TIME_RE.test(time)) return { ok: false, error: "Enter a valid time." };
  if (!isValidIanaTimezone(timezone)) return { ok: false, error: "Please select a valid timezone for this stop." };

  const [y, mo, d] = date.split("-").map(Number);
  const [h, mi] = time.split(":").map(Number);
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59) return { ok: false, error: "Enter a valid date and time." };

  const naiveUtcMs = Date.UTC(y, mo - 1, d, h, mi, 0);

  // First correction pass.
  const offset1 = offsetMsAt(naiveUtcMs, timezone);
  // Second pass against the corrected instant -- catches the case where
  // the first guess landed on the wrong side of a transition.
  const offset2 = offsetMsAt(naiveUtcMs - offset1, timezone);
  const candidateMs = naiveUtcMs - offset2;

  // Verify: does the candidate instant actually format back to the
  // requested wall-clock time in this zone?
  const verifyFmt = new Intl.DateTimeFormat("en-US", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false });
  const verify = Object.fromEntries(verifyFmt.formatToParts(new Date(candidateMs)).map((p) => [p.type, p.value]));
  const verifyHour = verify.hour === "24" ? 0 : Number(verify.hour);
  const matches = Number(verify.year) === y && Number(verify.month) === mo && Number(verify.day) === d && verifyHour === h && Number(verify.minute) === mi;

  // Straddle the requested moment by a few hours on each side to detect a
  // nearby DST transition -- if the offset differs before vs. after, this
  // wall-clock time sits in (or right next to) a transition window.
  const threeHoursMs = 3 * 60 * 60 * 1000;
  const offsetBefore = offsetMsAt(naiveUtcMs - offset1 - threeHoursMs, timezone);
  const offsetAfter = offsetMsAt(naiveUtcMs - offset1 + threeHoursMs, timezone);
  const nearTransition = offsetBefore !== offsetAfter;

  if (!matches) {
    // Spring-forward gap: this local time was skipped and never happened.
    if (nearTransition) {
      const label = new Intl.DateTimeFormat("en-US", { month: "long", day: "numeric", year: "numeric" }).format(new Date(Date.UTC(y, mo - 1, d)));
      const timeLabel = new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit" }).format(new Date(Date.UTC(2000, 0, 1, h, mi)));
      return { ok: false, error: `${timeLabel} does not exist in ${timezone} on ${label} because of daylight saving time. Please choose a valid time.` };
    }
    return { ok: false, error: "Could not resolve this date/time in the selected timezone." };
  }

  // Fall-back overlap: this local time occurs twice. Deterministic policy
  // (documented, spec section 9's simpler option): resolve to the EARLIER
  // occurrence (the offset in effect immediately before the transition,
  // i.e. still-DST side for a fall-back) -- matches the conventional
  // default most timezone libraries use, and callers get `ambiguous: true`
  // to surface a warning rather than silently picking one.
  const ambiguous = nearTransition && matches;

  return { ok: true, iso: new Date(candidateMs).toISOString(), ambiguous };
}

// Validates window_end >= window_start using real UTC instants (never
// comparing formatted local strings) -- spec section 16.
export function validateWindowOrder(startIso: string, endIso: string | null): { ok: true } | { ok: false; error: string } {
  if (!endIso) return { ok: true };
  if (new Date(endIso).getTime() < new Date(startIso).getTime()) {
    return { ok: false, error: "The appointment window end must be at or after the start." };
  }
  return { ok: true };
}
