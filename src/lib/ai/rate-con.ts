// AI entry from a rate confirmation (or BOL / manifest): what we ask the model
// for, and how its answer is cleaned up before it touches the New Load form.
// Pure -- no I/O -- so the rules are unit-tested. The model only SUGGESTS;
// the dispatcher reviews every highlighted field and saves.

export const EQUIPMENT_VALUES = ["dry_van", "reefer", "flatbed", "step_deck", "lowboy", "tanker", "other"] as const;
export type Equipment = (typeof EQUIPMENT_VALUES)[number];

export const STOP_TIMEZONES = ["America/New_York", "America/Chicago", "America/Denver", "America/Phoenix", "America/Los_Angeles", "America/Anchorage", "Pacific/Honolulu"] as const;

// Every field is always present; "" / 0 mean "not on the document" (no
// nullable unions -- keeps the schema inside structured-output limits).
const str = { type: "string" };
const num = { type: "number" };
const obj = (properties: Record<string, unknown>) => ({ type: "object", properties, required: Object.keys(properties), additionalProperties: false });

export const RATE_CON_SCHEMA = obj({
  document_kind: { type: "string", enum: ["rate_confirmation", "bill_of_lading", "manifest", "other"] },
  broker_name: str,
  broker_mc_number: str,
  load_reference: str,
  rate_total: num,
  linehaul: num,
  accessorials: { type: "array", items: obj({ description: str, amount: num }) },
  equipment_type: { type: "string", enum: [...EQUIPMENT_VALUES, ""] },
  commodity: str,
  weight_lbs: num,
  pieces: num,
  total_miles: num,
  stops: {
    type: "array",
    items: obj({
      stop_type: { type: "string", enum: ["pickup", "delivery"] },
      facility_name: str,
      address_line1: str,
      address_line2: str,
      city: str,
      state: str,
      postal_code: str,
      contact_name: str,
      contact_phone: str,
      date: str,
      time: str,
      window_end: str,
      timezone: { type: "string", enum: [...STOP_TIMEZONES, ""] },
      reference_number: str,
      notes: str,
    }),
  },
  special_instructions: str,
  uncertain_fields: { type: "array", items: str },
  notes_for_dispatcher: { type: "array", items: str },
});

export const RATE_CON_PROMPT = `You are reading a trucking document (usually a broker's rate confirmation; sometimes a bill of lading or manifest) so a dispatcher doesn't have to retype it.

Extract ONLY what is printed on the document. Never guess or invent a value: if something isn't on the document, use "" for text and 0 for numbers.

Rules:
- broker_name: the brokerage that issued the document (not the shipper, receiver or carrier). broker_mc_number: its MC number, digits only.
- load_reference: the broker's load / order / confirmation number.
- rate_total: the total agreed carrier pay in US dollars (linehaul + listed accessorials, as stated). linehaul: the base rate if shown separately. accessorials: each extra charge listed (detention, lumper, stop-off, fuel surcharge, ...).
- equipment_type: one of dry_van, reefer, flatbed, step_deck, lowboy, tanker, other ("" if not stated). Van / 53' dry -> dry_van; refrigerated -> reefer.
- weight_lbs in pounds; pieces = piece / pallet / case count; total_miles if printed.
- stops: every pickup and delivery IN ROUTE ORDER. date as YYYY-MM-DD; time and window_end as 24-hour HH:MM (for a window like 08:00-14:00 use time=08:00, window_end=14:00; for "FCFS" or no time leave time ""). state as the 2-letter code. timezone: the IANA zone of that stop's location from the allowed list. reference_number: the stop's PU#/PO#/appointment#/delivery#. Put dock hours, "FCFS", "appointment required" and similar in notes.
- special_instructions: driver/load requirements worth keeping (temperature, tarps, PPE, tracking requirements), short.
- uncertain_fields: paths of anything you filled but are not sure about, e.g. "rate_total", "stops[1].time".
- notes_for_dispatcher: short warnings, e.g. "Two delivery dates printed; used the appointment date", "Rate shown is per mile".
Return only the JSON object.`;

export type ExtractedStop = {
  stop_type: "pickup" | "delivery";
  facility_name: string;
  address_line1: string;
  address_line2: string;
  city: string;
  state: string;
  postal_code: string;
  contact_name: string;
  contact_phone: string;
  date: string;
  time: string;
  window_end: string;
  timezone: string;
  reference_number: string;
  notes: string;
};

export type ExtractedLoad = {
  document_kind: string;
  broker_name: string;
  broker_mc_number: string;
  load_reference: string;
  rate_total: number;
  linehaul: number;
  accessorials: { description: string; amount: number }[];
  equipment_type: Equipment | "";
  commodity: string;
  weight_lbs: number;
  pieces: number;
  total_miles: number;
  stops: ExtractedStop[];
  special_instructions: string;
  uncertain_fields: string[];
  notes_for_dispatcher: string[];
};

/** The model's text -> its JSON object (tolerates ```json fences or stray text around it). */
export function parseModelJson(text: string): unknown {
  const t = text.trim();
  try {
    return JSON.parse(t);
  } catch {
    const start = t.indexOf("{");
    const end = t.lastIndexOf("}");
    if (start >= 0 && end > start) return JSON.parse(t.slice(start, end + 1));
    throw new Error("The document could not be read.");
  }
}

const s = (v: unknown, max = 200) => (typeof v === "string" ? v.replace(/\s+/g, " ").trim().slice(0, max) : "");
const n = (v: unknown) => {
  const x = typeof v === "number" ? v : typeof v === "string" ? Number(v.replace(/[$,\s]/g, "")) : NaN;
  return Number.isFinite(x) && x > 0 ? Math.round(x * 100) / 100 : 0;
};

function cleanDate(v: unknown): string {
  const t = s(v, 20);
  if (/^\d{4}-\d{2}-\d{2}$/.test(t)) return t;
  const m = t.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2,4})$/);
  if (m) {
    const y = m[3].length === 2 ? `20${m[3]}` : m[3];
    return `${y}-${m[1].padStart(2, "0")}-${m[2].padStart(2, "0")}`;
  }
  return "";
}

function cleanTime(v: unknown): string {
  const t = s(v, 20).toUpperCase();
  let m = t.match(/^(\d{1,2}):?(\d{2})$/);
  if (m && Number(m[1]) < 24 && Number(m[2]) < 60) return `${m[1].padStart(2, "0")}:${m[2]}`;
  m = t.match(/^(\d{1,2})(?::(\d{2}))?\s*(AM|PM)$/);
  if (m) {
    let h = Number(m[1]) % 12;
    if (m[3] === "PM") h += 12;
    return `${String(h).padStart(2, "0")}:${m[2] ?? "00"}`;
  }
  return "";
}

const cleanState = (v: unknown) => {
  const t = s(v, 30).toUpperCase().replace(/[^A-Z]/g, "");
  return t.length === 2 ? t : "";
};

/** Model output -> safe values for the form (bad dates/times/states dropped, not guessed). */
export function normalizeExtraction(raw: unknown): ExtractedLoad {
  const r = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  const stops = (Array.isArray(r.stops) ? r.stops : []).slice(0, 12).map((x) => {
    const st = (x && typeof x === "object" ? x : {}) as Record<string, unknown>;
    const tz = s(st.timezone, 40);
    return {
      stop_type: st.stop_type === "delivery" ? "delivery" : "pickup",
      facility_name: s(st.facility_name),
      address_line1: s(st.address_line1),
      address_line2: s(st.address_line2),
      city: s(st.city, 80),
      state: cleanState(st.state),
      postal_code: s(st.postal_code, 10).replace(/[^0-9A-Za-z -]/g, ""),
      contact_name: s(st.contact_name, 80),
      contact_phone: s(st.contact_phone, 40),
      date: cleanDate(st.date),
      time: cleanTime(st.time),
      window_end: cleanTime(st.window_end),
      timezone: (STOP_TIMEZONES as readonly string[]).includes(tz) ? tz : "",
      reference_number: s(st.reference_number, 80),
      notes: s(st.notes, 500),
    } satisfies ExtractedStop;
  });
  const eq = s(r.equipment_type, 20);
  const rate = n(r.rate_total);
  const accessorials = (Array.isArray(r.accessorials) ? r.accessorials : [])
    .slice(0, 10)
    .map((a) => ({ description: s((a as Record<string, unknown>)?.description, 80), amount: n((a as Record<string, unknown>)?.amount) }))
    .filter((a) => a.description || a.amount);
  return {
    document_kind: s(r.document_kind, 30) || "other",
    broker_name: s(r.broker_name, 120),
    broker_mc_number: s(r.broker_mc_number, 20).replace(/\D/g, ""),
    load_reference: s(r.load_reference, 80),
    rate_total: rate || n(r.linehaul) + accessorials.reduce((t, a) => t + a.amount, 0),
    linehaul: n(r.linehaul),
    accessorials,
    equipment_type: (EQUIPMENT_VALUES as readonly string[]).includes(eq) ? (eq as Equipment) : "",
    commodity: s(r.commodity, 120),
    weight_lbs: n(r.weight_lbs),
    pieces: n(r.pieces),
    total_miles: n(r.total_miles),
    stops,
    special_instructions: s(r.special_instructions, 1000),
    uncertain_fields: (Array.isArray(r.uncertain_fields) ? r.uncertain_fields : []).map((x) => s(x, 60)).filter(Boolean).slice(0, 30),
    notes_for_dispatcher: (Array.isArray(r.notes_for_dispatcher) ? r.notes_for_dispatcher : []).map((x) => s(x, 200)).filter(Boolean).slice(0, 10),
  };
}

/** Main pickup = first pickup; main delivery = last delivery; the rest are additional stops (in order). */
export function splitStops(stops: ExtractedStop[]): { pickup: ExtractedStop | null; delivery: ExtractedStop | null; extra: ExtractedStop[] } {
  const pi = stops.findIndex((x) => x.stop_type === "pickup");
  let di = -1;
  for (let i = stops.length - 1; i >= 0; i--) if (stops[i].stop_type === "delivery") { di = i; break; }
  return {
    pickup: pi >= 0 ? stops[pi] : null,
    delivery: di >= 0 ? stops[di] : null,
    extra: stops.filter((_, i) => i !== pi && i !== di),
  };
}

/** Pick the broker from your list: MC number first, then name (ignoring LLC/Inc/punctuation). */
export function matchBroker(brokers: { id: string; company_name: string; mc_number: string | null }[], name: string, mc: string): string | null {
  const digits = (x: string | null) => (x ?? "").replace(/\D/g, "");
  if (mc) {
    const byMc = brokers.find((b) => digits(b.mc_number) && digits(b.mc_number) === mc);
    if (byMc) return byMc.id;
  }
  const key = (x: string) => x.toLowerCase().replace(/[.,&'"]/g, " ").replace(/\b(llc|inc|corp|co|ltd|logistics|freight|transportation|services|group)\b/g, " ").replace(/\s+/g, " ").trim();
  const k = key(name);
  if (!k) return null;
  const exact = brokers.find((b) => key(b.company_name) === k);
  if (exact) return exact.id;
  const partial = brokers.filter((b) => key(b.company_name) && (key(b.company_name).includes(k) || k.includes(key(b.company_name))));
  return partial.length === 1 ? partial[0].id : null;
}
