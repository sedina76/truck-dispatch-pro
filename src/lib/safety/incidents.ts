// Safety incidents: accidents, citations, cargo claims and inspection
// violations. Pure (no I/O) -- the form values, labels and the safety
// history summary shown on driver and truck pages.

export const INCIDENT_TYPES = ["accident", "citation", "cargo_claim", "inspection_violation"] as const;
export type IncidentType = (typeof INCIDENT_TYPES)[number];

export const INCIDENT_TYPE_LABEL: Record<IncidentType, string> = {
  accident: "Accident",
  citation: "Citation",
  cargo_claim: "Cargo claim",
  inspection_violation: "Inspection violation",
};

export const INCIDENT_STATUSES = ["open", "closed"] as const;
export type IncidentStatus = (typeof INCIDENT_STATUSES)[number];

export function incidentTypeLabel(t: string | null | undefined): string {
  return (t && INCIDENT_TYPE_LABEL[t as IncidentType]) || "Incident";
}

export type IncidentValues = {
  incident_type: IncidentType;
  occurred_on: string;
  location: string | null;
  driver_id: string | null;
  truck_id: string | null;
  load_id: string | null;
  description: string | null;
  cost: number;
};

type FormLike = { get(name: string): unknown };

function text(f: FormLike, name: string, max: number): string | null {
  const v = String(f.get(name) ?? "").trim();
  return v ? v.slice(0, max) : null;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function id(f: FormLike, name: string): string | null {
  const v = String(f.get(name) ?? "").trim();
  return UUID.test(v) ? v : null;
}

/** Reads and checks the incident form. Throws a plain-language message on bad input. */
export function incidentValues(f: FormLike, today: string): IncidentValues {
  const type = String(f.get("incident_type") ?? "");
  if (!(INCIDENT_TYPES as readonly string[]).includes(type)) throw new Error("Choose what kind of incident this was.");

  const occurredOn = String(f.get("occurred_on") ?? "").trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(occurredOn) || Number.isNaN(Date.parse(`${occurredOn}T12:00:00Z`))) throw new Error("Enter the date it happened.");
  if (occurredOn > today) throw new Error("The incident date can't be in the future.");

  const rawCost = String(f.get("cost") ?? "").replace(/[$,\s]/g, "");
  const cost = rawCost === "" ? 0 : Number(rawCost);
  if (!Number.isFinite(cost) || cost < 0) throw new Error("Cost must be zero or more.");
  if (cost > 9_999_999_999) throw new Error("Cost is too large.");

  return {
    incident_type: type as IncidentType,
    occurred_on: occurredOn,
    location: text(f, "location", 300),
    driver_id: id(f, "driver_id"),
    truck_id: id(f, "truck_id"),
    load_id: id(f, "load_id"),
    description: text(f, "description", 5000),
    cost: Math.round(cost * 100) / 100,
  };
}

export type HistoryRow = { incident_type: string; occurred_on: string; cost: number | string | null; status: string };

export type SafetySummary = {
  total: number;
  open: number;
  last12Months: number;
  totalCost: number;
  byType: { type: IncidentType; label: string; count: number }[];
};

/** Counts for a driver's or truck's safety history. `today` is YYYY-MM-DD. */
export function summarizeHistory(rows: HistoryRow[], today: string): SafetySummary {
  const d = new Date(`${today}T12:00:00Z`);
  d.setUTCFullYear(d.getUTCFullYear() - 1);
  const yearAgo = d.toISOString().slice(0, 10);
  return {
    total: rows.length,
    open: rows.filter((r) => r.status === "open").length,
    last12Months: rows.filter((r) => r.occurred_on > yearAgo).length,
    totalCost: Math.round(rows.reduce((s, r) => s + (Number(r.cost) || 0), 0) * 100) / 100,
    byType: INCIDENT_TYPES.map((t) => ({ type: t, label: INCIDENT_TYPE_LABEL[t], count: rows.filter((r) => r.incident_type === t).length })).filter((x) => x.count > 0),
  };
}

/** Which documents.document_type a file is stored as: pictures are photos, everything else "other". */
export function incidentFileType(mime: string): "incident_photo" | "other" {
  return mime.startsWith("image/") ? "incident_photo" : "other";
}

export const INCIDENT_FILE_TYPES = new Set(["image/jpeg", "image/png", "application/pdf"]);
export const INCIDENT_FILE_MAX_BYTES = 15 * 1024 * 1024;
