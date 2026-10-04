// Fills the New Load form from an AI-read rate confirmation (DOM only, no
// React state): sets values by field name, outlines what was filled (amber
// = the AI wasn't sure), adds extra stops, attaches the document, opens the
// sections. Never submits -- the dispatcher reviews and clicks Create Load.
import { splitStops, type ExtractedLoad, type ExtractedStop } from "@/lib/ai/rate-con";

export type Summary = { filled: number; check: string[]; notes: string[]; brokerMissing: string | null; brokerMc: string; extraStops: number; kind: string };

const STOP_FIELDS: [keyof ExtractedStop, string][] = [
  ["facility_name", "facility_name"],
  ["address_line1", "address_line1"],
  ["address_line2", "address_line2"],
  ["city", "city"],
  ["state", "state"],
  ["postal_code", "postal_code"],
  ["contact_name", "contact_name"],
  ["contact_phone", "contact_phone"],
  ["date", "date"],
  ["time", "time"],
  ["window_end", "window_end"],
  ["timezone", "timezone"],
  ["reference_number", "reference_number"],
  ["notes", "notes"],
];

const LABEL: Record<string, string> = {
  rate: "Rate",
  rate_confirmation_number: "Rate Confirmation #",
  broker_id: "Broker",
  equipment_type: "Equipment",
  commodity: "Commodity",
  weight_lbs: "Weight",
  total_miles: "Total Miles",
};

function money(n: number) {
  return `$${n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

type Field = HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement;

export function fillForm(form: HTMLFormElement, load: ExtractedLoad, brokerId: string | null, file: File): Summary {
  // clear marks from an earlier fill
  form.querySelectorAll("[data-ai-filled]").forEach((el) => el.removeAttribute("data-ai-filled"));
  let filled = 0;
  const check: string[] = [];
  const uncertain = new Set(load.uncertain_fields.map((x) => x.toLowerCase()));

  const set = (name: string, value: string | number, opts: { uncertain?: boolean; onlyIfEmpty?: boolean } = {}) => {
    if (value === "" || value === 0) return;
    const el = form.elements.namedItem(name) as Field | null;
    if (!el || !("value" in el)) return;
    if (opts.onlyIfEmpty && el.value) return;
    const v = String(value);
    if (el instanceof HTMLSelectElement && !Array.from(el.options).some((o) => o.value === v)) return;
    el.value = v;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    el.setAttribute("data-ai-filled", opts.uncertain ? "check" : "1");
    el.addEventListener("input", () => el.removeAttribute("data-ai-filled"), { once: true, capture: false });
    filled++;
    if (opts.uncertain) check.push(LABEL[name] ?? name.replace(/^(pickup|delivery)_/, "$1 ").replace(/_/g, " "));
  };

  // Load-level fields
  if (brokerId) set("broker_id", brokerId, { uncertain: uncertain.has("broker_name") });
  set("rate_confirmation_number", load.load_reference, { uncertain: uncertain.has("load_reference") });
  set("rate", load.rate_total, { uncertain: uncertain.has("rate_total") || uncertain.has("linehaul") });
  set("equipment_type", load.equipment_type, { uncertain: uncertain.has("equipment_type") });
  set("commodity", load.commodity, { uncertain: uncertain.has("commodity") });
  set("weight_lbs", load.weight_lbs, { uncertain: uncertain.has("weight_lbs") });
  set("total_miles", load.total_miles, { uncertain: uncertain.has("total_miles") });

  const extras: string[] = [];
  if (load.special_instructions) extras.push(load.special_instructions);
  if (load.accessorials.length) extras.push(`Accessorials: ${load.accessorials.map((a) => `${a.description}${a.amount ? ` ${money(a.amount)}` : ""}`).join("; ")}`);
  if (load.pieces) extras.push(`Pieces: ${load.pieces}`);
  set("special_instructions", extras.join("\n"), { onlyIfEmpty: true });

  // Stops: first pickup -> Pickup, last delivery -> Delivery, the rest -> Additional Stops
  const { pickup, delivery, extra } = splitStops(load.stops);
  const fillStop = (stop: ExtractedStop | null, prefix: "pickup" | "delivery") => {
    if (!stop) return;
    const idx = load.stops.indexOf(stop);
    for (const [key, field] of STOP_FIELDS) {
      const value = stop[key];
      if (typeof value !== "string") continue;
      set(`${prefix}_${field}`, value, { uncertain: uncertain.has(`stops[${idx}].${key}`) });
    }
  };
  fillStop(pickup, "pickup");
  fillStop(delivery, "delivery");
  if (extra.length) {
    window.dispatchEvent(
      new CustomEvent("tdp:set-extra-stops", {
        detail: extra.map((st) => ({
          stop_type: st.stop_type,
          values: Object.fromEntries(STOP_FIELDS.map(([k, f]) => [f, String(st[k] ?? "")]).filter(([, v]) => v)),
        })),
      })
    );
    filled += extra.length;
  }

  // Attach the same document as the load's Rate Confirmation
  const doc = form.elements.namedItem("rate_confirmation_file") as HTMLInputElement | null;
  if (doc && load.document_kind !== "bill_of_lading" && load.document_kind !== "manifest") {
    try {
      const dt = new DataTransfer();
      dt.items.add(file);
      doc.files = dt.files;
    } catch {
      // older browsers: the dispatcher can attach it by hand
    }
  }

  // Open every section so the filled fields are visible
  window.dispatchEvent(new CustomEvent("tdp:open-sections"));

  return {
    filled,
    check,
    notes: load.notes_for_dispatcher,
    brokerMissing: !brokerId && load.broker_name ? load.broker_name : null,
    brokerMc: load.broker_mc_number,
    extraStops: extra.length,
    kind: load.document_kind,
  };
}
