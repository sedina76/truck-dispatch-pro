// Suggests a stop's IANA timezone from its US state and ZIP code, so the
// New Load form can pre-select the right Timezone as the dispatcher types
// the address. It is only a SUGGESTION in the form -- the dispatcher can
// always change the dropdown, and whatever is submitted is what is saved.
//
// Why state alone is not enough (see resolve.ts): FL, IN, KY, TN, TX, KS,
// NE, SD, ND, OR, ID, MI and AZ span more than one zone. For those states
// the ZIP code's first three digits (its sectional center) pick the zone.
// Where even one 3-digit ZIP area straddles a zone line, or the state is
// split and no ZIP was given, the result is marked "check" so the form
// tells the dispatcher to confirm instead of silently guessing.
//
// Every zone used here is in COMMON_TIMEZONES (iana.ts), so the suggestion
// is always an option the dropdown actually has.

export type TimezoneSuggestion = {
  timezone: string;
  /** "exact": state (and ZIP, where it matters) settle the zone. "check": best guess, confirm it. */
  certainty: "exact" | "check";
  /** Plain-language reason shown under the dropdown. */
  reason: string;
};

const ET = "America/New_York";
const CT = "America/Chicago";
const MT = "America/Denver";
const AZ = "America/Phoenix";
const PT = "America/Los_Angeles";
const AK = "America/Anchorage";
const HI = "Pacific/Honolulu";

/** Zone for each state; for split states, the zone most of the state uses. */
const STATE_ZONE: Record<string, string> = {
  AL: CT, AK: AK, AZ: AZ, AR: CT, CA: PT, CO: MT, CT: ET, DE: ET, DC: ET, FL: ET,
  GA: ET, HI: HI, ID: MT, IL: CT, IN: ET, IA: CT, KS: CT, KY: ET, LA: CT, ME: ET,
  MD: ET, MA: ET, MI: ET, MN: CT, MS: CT, MO: CT, MT: MT, NE: CT, NV: PT, NH: ET,
  NJ: ET, NM: MT, NY: ET, NC: ET, ND: CT, OH: ET, OK: CT, OR: PT, PA: ET, RI: ET,
  SC: ET, SD: CT, TN: CT, TX: CT, UT: MT, VT: ET, VA: ET, WA: PT, WV: ET, WI: CT,
  WY: MT,
};

/**
 * Split states: 3-digit ZIP prefix -> zone, for prefixes that differ from the
 * state's main zone (or that must be stated explicitly, like East Tennessee).
 */
const ZIP3_ZONE: Record<string, Record<string, string>> = {
  FL: { "324": CT, "325": CT }, // Panhandle: Panama City, Pensacola
  IN: { "463": CT, "464": CT, "476": CT, "477": CT }, // Gary/Hammond, Evansville
  KY: { "420": CT, "421": CT, "422": CT, "423": CT, "424": CT }, // Paducah, Bowling Green, Owensboro
  TN: { "373": ET, "374": ET, "376": ET, "377": ET, "378": ET, "379": ET }, // Chattanooga, Tri-Cities, Knoxville
  TX: { "798": MT, "799": MT, "885": MT }, // El Paso area
  NE: { "693": MT }, // Scottsbluff, Alliance
  SD: { "577": MT }, // Rapid City
  ND: { "586": MT }, // Dickinson
  OR: { "979": MT }, // Ontario (Malheur County)
  ID: { "835": PT, "838": PT }, // Lewiston, Coeur d'Alene
};

/** 3-digit ZIP areas that straddle a zone line: suggest, but ask to confirm. */
const ZIP3_MIXED: Record<string, Set<string>> = {
  FL: new Set(["324"]),
  KY: new Set(["427"]),
  TN: new Set(["373"]),
  KS: new Set(["677", "678"]),
  NE: new Set(["690", "691", "692"]),
  SD: new Set(["575", "576"]),
  ND: new Set(["585"]),
  ID: new Set(["835"]),
  MI: new Set(["498", "499"]),
  AZ: new Set(["865"]), // Navajo Nation observes daylight saving time
};

const SPLIT_STATES = new Set(["FL", "IN", "KY", "TN", "TX", "KS", "NE", "SD", "ND", "OR", "ID", "MI", "AZ"]);

const ZONE_NAME: Record<string, string> = {
  [ET]: "Eastern",
  [CT]: "Central",
  [MT]: "Mountain",
  [AZ]: "Arizona",
  [PT]: "Pacific",
  [AK]: "Alaska",
  [HI]: "Hawaii",
};

export function zoneShortName(timezone: string): string {
  return ZONE_NAME[timezone] ?? timezone;
}

/** First 3 digits of a complete 5-digit ZIP (ZIP+4 ok), else null. */
function zip3(zip: string | null | undefined): string | null {
  const digits = String(zip ?? "").replace(/\D/g, "");
  return digits.length === 5 || digits.length === 9 ? digits.slice(0, 3) : null;
}

export function suggestTimezone(state: string | null | undefined, zip: string | null | undefined): TimezoneSuggestion | null {
  const st = String(state ?? "").trim().toUpperCase();
  const base = STATE_ZONE[st];
  if (!base) return null;

  const z3 = zip3(zip);
  if (!SPLIT_STATES.has(st)) {
    return { timezone: base, certainty: "exact", reason: `${zoneShortName(base)} Time, from ${st}` };
  }

  if (!z3) {
    return {
      timezone: base,
      certainty: "check",
      reason: `${st} has more than one time zone. Add the ZIP or check this.`,
    };
  }

  const timezone = ZIP3_ZONE[st]?.[z3] ?? base;
  if (ZIP3_MIXED[st]?.has(z3)) {
    return {
      timezone,
      certainty: "check",
      reason: `ZIP ${z3}xx sits on a time zone line. Check this.`,
    };
  }
  return { timezone, certainty: "exact", reason: `${zoneShortName(timezone)} Time, from ${st} ${z3}xx` };
}
