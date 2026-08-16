// ---------------------------------------------------------------------------
// IANA timezone validation + the curated list this app's forms offer.
//
// No new dependency: Node 25 / modern browsers both ship a complete IANA
// timezone database behind Intl, including Intl.supportedValuesOf('timeZone')
// as the authoritative "is this a real zone" source -- confirmed live
// (418 zones on this app's Node runtime) before choosing this over adding
// a library (spec section 6: reuse native APIs when they're genuinely
// sufficient, which they are for validation).
// ---------------------------------------------------------------------------

let cachedValidZones: Set<string> | null = null;

function validZoneSet(): Set<string> {
  if (!cachedValidZones) {
    cachedValidZones = new Set(Intl.supportedValuesOf("timeZone"));
    cachedValidZones.add("UTC"); // always valid, not always listed depending on runtime
  }
  return cachedValidZones;
}

// Rejects ambiguous abbreviations ("CST"), free text ("Central Time"),
// fixed-offset strings ("UTC-6"), and anything not a real IANA identifier
// ("America/FakeCity") -- only a genuine zone from the canonical IANA list
// passes.
//
// Deliberately does NOT fall back to a bare `new Intl.DateTimeFormat({
// timeZone })` try/catch as a second check: ICU treats legacy three-letter
// aliases like "CST"/"EST" as valid input and silently resolves them to a
// canonical zone (e.g. "CST" -> "America/Chicago") even though they are
// NOT in Intl.supportedValuesOf('timeZone') and are exactly the ambiguous,
// DST-unsafe input this function exists to reject -- confirmed live before
// removing that fallback (it let "CST" through as "valid" in an earlier
// version of this function).
export function isValidIanaTimezone(timezone: unknown): timezone is string {
  if (typeof timezone !== "string" || timezone.trim().length === 0) return false;
  return validZoneSet().has(timezone);
}

// Curated for a US trucking operation -- not all 418 IANA zones (spec
// section 10: "do not show hundreds of raw timezone choices"). Every
// value here is validated by isValidIanaTimezone() in a live test before
// this file is considered correct.
export const COMMON_TIMEZONES: { value: string; label: string }[] = [
  { value: "America/New_York", label: "Eastern Time — America/New_York" },
  { value: "America/Chicago", label: "Central Time — America/Chicago" },
  { value: "America/Denver", label: "Mountain Time — America/Denver" },
  { value: "America/Phoenix", label: "Arizona (no DST) — America/Phoenix" },
  { value: "America/Los_Angeles", label: "Pacific Time — America/Los_Angeles" },
  { value: "America/Anchorage", label: "Alaska — America/Anchorage" },
  { value: "Pacific/Honolulu", label: "Hawaii — Pacific/Honolulu" },
  { value: "UTC", label: "UTC" },
];
