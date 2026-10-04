// Address -> map point, pure parts (URLs and response parsing). The fetching
// lives in stop-geocoding.ts. Two free services, no API key:
//
//   1. US Census geocoder -- street addresses in the US. Official, free, no
//      key, no published rate limit for single lookups.
//   2. OpenStreetMap Nominatim -- street addresses the Census didn't match,
//      Canada/Mexico, and (as a last resort) the city center. Free with a
//      usage policy: identify the app (User-Agent), at most 1 request/second,
//      no bulk jobs. We look up a few stops per load, once, and cache the
//      result on the stop, which is well inside that.
//
// Set GEOCODER=none to turn lookups off; NOMINATIM_BASE_URL can point at a
// self-hosted or paid Nominatim-compatible host.

export type StopAddress = {
  address_line1: string | null;
  city: string | null;
  state: string | null;
  postal_code: string | null;
  country: string | null;
};

export type GeoPoint = { latitude: number; longitude: number };

const clean = (s: string | null | undefined) => (s ?? "").replace(/\s+/g, " ").trim();

export function isUsAddress(a: StopAddress): boolean {
  const c = clean(a.country).toUpperCase();
  return c === "" || c === "US" || c === "USA" || c === "UNITED STATES";
}

function countryCode(a: StopAddress): string {
  const c = clean(a.country).toUpperCase();
  if (c === "CA" || c === "CANADA") return "ca";
  if (c === "MX" || c === "MEXICO") return "mx";
  return "us";
}

function validPoint(lat: number, lon: number): GeoPoint | null {
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
  if (lat === 0 && lon === 0) return null;
  return { latitude: lat, longitude: lon };
}

// ---- US Census -------------------------------------------------------------

export function censusUrl(a: StopAddress): string | null {
  const street = clean(a.address_line1);
  if (!street || !isUsAddress(a)) return null;
  const tail = [clean(a.city), [clean(a.state), clean(a.postal_code)].filter(Boolean).join(" ")].filter(Boolean).join(", ");
  if (!tail) return null;
  const q = new URLSearchParams({ address: `${street}, ${tail}`, benchmark: "Public_AR_Current", format: "json" });
  return `https://geocoding.geo.census.gov/geocoder/locations/onelineaddress?${q.toString()}`;
}

/** Census answers {result:{addressMatches:[{coordinates:{x: lon, y: lat}}]}}. */
export function parseCensus(body: unknown): GeoPoint | null {
  const matches = (body as { result?: { addressMatches?: { coordinates?: { x?: unknown; y?: unknown } }[] } } | null)?.result?.addressMatches;
  if (!Array.isArray(matches) || matches.length === 0) return null;
  const c = matches[0]?.coordinates;
  return validPoint(Number(c?.y), Number(c?.x));
}

// ---- OpenStreetMap Nominatim -----------------------------------------------

export const NOMINATIM_DEFAULT = "https://nominatim.openstreetmap.org";

/** Structured search. `street` false = the city (or ZIP) only. */
export function nominatimUrl(base: string, a: StopAddress, street: boolean): string | null {
  const city = clean(a.city);
  const state = clean(a.state);
  const zip = clean(a.postal_code);
  const line = clean(a.address_line1);
  if (street && !line) return null;
  if (!city && !zip) return null;
  const q = new URLSearchParams({ format: "jsonv2", limit: "1", countrycodes: countryCode(a), addressdetails: "0" });
  if (street) q.set("street", line);
  if (city) q.set("city", city);
  if (state) q.set("state", state);
  if (zip) q.set("postalcode", zip);
  return `${base.replace(/\/+$/, "")}/search?${q.toString()}`;
}

/**
 * Nominatim answers [{lat:"..", lon:"..", place_rank: n}]. place_rank 26+ is a
 * street or a building: only that counts as the stop's exact location. For the
 * city-center fallback any settlement / postcode result is accepted.
 */
export function parseNominatim(body: unknown, street: boolean): GeoPoint | null {
  if (!Array.isArray(body) || body.length === 0) return null;
  const r = body[0] as { lat?: unknown; lon?: unknown; place_rank?: unknown };
  if (street && Number(r.place_rank) < 26) return null;
  return validPoint(Number(r.lat), Number(r.lon));
}

// ---- Reverse: map point -> "Minneapolis, MN" --------------------------------

export function nominatimReverseUrl(base: string, latitude: number, longitude: number): string {
  // zoom 10 = city level: we only want the town name, never a street address
  const q = new URLSearchParams({ format: "jsonv2", lat: latitude.toFixed(4), lon: longitude.toFixed(4), zoom: "10", addressdetails: "1" });
  return `${base.replace(/\/+$/, "")}/reverse?${q.toString()}`;
}

/** {address:{city|town|village|hamlet|county, "ISO3166-2-lvl4": "US-MN", state}} -> "Minneapolis, MN". */
export function parseNominatimReverse(body: unknown): string | null {
  const a = (body as { address?: Record<string, string> } | null)?.address;
  if (!a) return null;
  const place = a.city || a.town || a.village || a.hamlet || a.municipality || a.county || null;
  const iso = a["ISO3166-2-lvl4"];
  const region = iso && /^[A-Z]{2}-[A-Z0-9]{1,3}$/.test(iso) ? iso.slice(3) : a.state || null;
  if (!place && !region) return null;
  return [place, region].filter(Boolean).join(", ");
}
