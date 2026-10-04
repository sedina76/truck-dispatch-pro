// Weather alerts along a truck's route, from the US National Weather Service
// (api.weather.gov -- free, no key). Pure parts: which points of the route to
// check, which alerts matter to a truck driver, and how to word them. The
// fetching (with a short cache) lives in route-alerts.ts.

export type RoutePoint = { lat: number; lon: number; where: string };

export type WeatherAlert = {
  id: string;
  event: string; // "Winter Storm Warning"
  severity: "Extreme" | "Severe" | "Moderate" | "Minor" | "Unknown";
  area: string; // "Laramie County, WY" (first area named)
  where: string; // "on route" | "at pickup (4BS)" | "at the truck"
  ends: string | null; // ISO
};

// Driving hazards worth a dispatcher's attention. Matched case-insensitively
// against the NWS event name ("Winter Storm Warning", "High Wind Watch", ...).
const HAZARD_WORDS = [
  "tornado",
  "blizzard",
  "winter storm",
  "ice storm",
  "winter weather",
  "freezing rain",
  "freezing fog",
  "snow squall",
  "lake effect snow",
  "high wind",
  "extreme wind",
  "wind advisory",
  "severe thunderstorm",
  "flash flood",
  "flood warning",
  "dense fog",
  "dust storm",
  "blowing dust",
  "hurricane",
  "tropical storm",
  "extreme cold",
  "wind chill warning",
  "avalanche",
];

export function isDrivingHazard(event: string): boolean {
  const e = event.toLowerCase();
  if (e.includes("statement") || e.includes("outlook") || e.includes("test")) return false;
  return HAZARD_WORDS.some((w) => e.includes(w));
}

const SEVERITIES = ["Extreme", "Severe", "Moderate", "Minor", "Unknown"] as const;
const RANK: Record<string, number> = { Extreme: 0, Severe: 1, Moderate: 2, Minor: 3, Unknown: 4 };
const KIND_RANK = (event: string) => (/warning/i.test(event) ? 0 : /watch/i.test(event) ? 1 : 2);

/** One api.weather.gov /alerts/active?point= answer -> the driving-hazard alerts in it. */
export function parseNwsAlerts(body: unknown, where: string): WeatherAlert[] {
  const features = (body as { features?: { properties?: Record<string, unknown> }[] } | null)?.features;
  if (!Array.isArray(features)) return [];
  const out: WeatherAlert[] = [];
  for (const f of features) {
    const p = f?.properties ?? {};
    const event = typeof p.event === "string" ? p.event : "";
    if (!event || !isDrivingHazard(event)) continue;
    if (p.status && p.status !== "Actual") continue;
    if (p.messageType === "Cancel") continue;
    const sev = typeof p.severity === "string" && (SEVERITIES as readonly string[]).includes(p.severity) ? (p.severity as WeatherAlert["severity"]) : "Unknown";
    const areaDesc = typeof p.areaDesc === "string" ? p.areaDesc : "";
    out.push({
      id: String(p.id ?? `${event}|${areaDesc}`),
      event,
      severity: sev,
      area: areaDesc.split(";")[0]?.trim() ?? "",
      where,
      ends: typeof p.ends === "string" ? p.ends : typeof p.expires === "string" ? p.expires : null,
    });
  }
  return out;
}

/** Same alert seen from several points counts once (the first place it was seen); worst first. */
export function mergeAlerts(lists: WeatherAlert[][]): WeatherAlert[] {
  const seen = new Map<string, WeatherAlert>();
  for (const list of lists) for (const a of list) if (!seen.has(a.id)) seen.set(a.id, a);
  return Array.from(seen.values()).sort((a, b) => RANK[a.severity] - RANK[b.severity] || KIND_RANK(a.event) - KIND_RANK(b.event) || a.event.localeCompare(b.event));
}

/**
 * The places to check for one truck: where it is now, a few points spread
 * along the calculated route to its next stop ([lon, lat] pairs), and its
 * stops. At most `max` points; nearby points are merged (the NWS answers by
 * forecast zone, so points ~25 km apart add little).
 */
export function routeCheckPoints(input: {
  truck: { lat: number; lon: number } | null;
  route: [number, number][] | null;
  stops: { lat: number; lon: number; label: string }[];
  max?: number;
}): RoutePoint[] {
  const max = input.max ?? 10;
  const pts: RoutePoint[] = [];
  if (input.truck) pts.push({ lat: input.truck.lat, lon: input.truck.lon, where: "at the truck" });
  const route = (input.route ?? []).filter((c) => Array.isArray(c) && Number.isFinite(c[0]) && Number.isFinite(c[1]));
  const routeSlots = Math.max(0, max - pts.length - input.stops.length);
  if (route.length > 2 && routeSlots > 0) {
    const step = (route.length - 1) / (routeSlots + 1);
    for (let i = 1; i <= routeSlots; i++) {
      const [lon, lat] = route[Math.round(i * step)];
      pts.push({ lat, lon, where: "on route" });
    }
  }
  for (const s of input.stops) pts.push({ lat: s.lat, lon: s.lon, where: `at ${s.label}` });
  // drop points within ~25 km of one already kept
  const kept: RoutePoint[] = [];
  for (const p of pts) {
    if (kept.some((k) => Math.abs(k.lat - p.lat) < 0.22 && Math.abs(k.lon - p.lon) < 0.3)) continue;
    kept.push({ ...p, lat: Math.round(p.lat * 10000) / 10000, lon: Math.round(p.lon * 10000) / 10000 });
  }
  return kept.slice(0, max);
}

/** "Winter Storm Warning -- on route, Laramie County, WY (until Mon 6:00 AM)". */
export function alertLine(a: WeatherAlert, timeZone?: string): string {
  let until = "";
  if (a.ends) {
    try {
      until = ` (until ${new Intl.DateTimeFormat("en-US", { timeZone, weekday: "short", hour: "numeric", minute: "2-digit" }).format(new Date(a.ends))})`;
    } catch {
      until = "";
    }
  }
  return `${a.event} -- ${a.where}${a.area ? `, ${a.area}` : ""}${until}`;
}

export function alertTone(a: WeatherAlert): "danger" | "warning" {
  return a.severity === "Extreme" || a.severity === "Severe" || /warning/i.test(a.event) ? "danger" : "warning";
}
