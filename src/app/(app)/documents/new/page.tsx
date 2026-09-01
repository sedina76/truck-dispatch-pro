import { createClient } from "@/lib/supabase/server";
import {
  NEW_DOCUMENT_ENTITY_TYPE_SET,
  type NewDocumentEntityType,
} from "@/lib/documents/library";
import { AddDocumentRouter, type EntityOption } from "@/components/documents/add-document-router";

// Global "Add Document" is a workflow ROUTER -- it never writes a documents
// row. It sends the user to the selected record's real upload workflow, or
// tells them one doesn't exist yet. Every selector list is RLS-scoped to
// the caller's organization; contextual ?entity_type=&entity_id= params
// only pre-select. This page pre-computes every display string for the
// searchable RecordPicker so that component stays presentation-only.

const LIST_LIMIT = 500;

// MC / DOT display normalizer -- if the stored value already starts with
// the prefix (e.g. "MC-12345"), don't prepend it again. PRESENTATION ONLY;
// the stored value is never changed.
function formatIdentifier(prefix: "MC" | "DOT", raw: string | null | undefined): string | null {
  const v = (raw ?? "").trim();
  if (!v) return null;
  const stripped = v.replace(new RegExp(`^${prefix}[-\\s]*`, "i"), "").trim();
  if (!stripped) return null;
  return `${prefix}-${stripped}`;
}

function joinDot(parts: (string | null | undefined)[]): string | null {
  const kept = parts.filter((p): p is string => !!p && p.trim() !== "");
  return kept.length ? kept.join(" · ") : null;
}

function cityState(city: string | null | undefined, state: string | null | undefined): string | null {
  const c = (city ?? "").trim();
  const s = (state ?? "").trim();
  if (c && s) return `${c}, ${s}`;
  return c || s || null;
}

type LoadStopLite = { stop_type: "pickup" | "delivery"; stop_sequence: number; city: string | null; state: string | null };

export default async function NewDocumentPage({
  searchParams,
}: {
  searchParams: Promise<{ entity_type?: string; entity_id?: string }>;
}) {
  const { entity_type, entity_id } = await searchParams;
  const supabase = await createClient();

  const [
    { data: carriers },
    { data: drivers },
    { data: loads },
    { data: brokers },
    { data: customers },
  ] = await Promise.all([
    supabase.from("carriers").select("id, legal_name, dba_name, mc_number, dot_number").order("legal_name").limit(LIST_LIMIT),
    supabase.from("drivers").select("id, first_name, last_name, cdl_number, cdl_state, status").order("last_name").limit(LIST_LIMIT),
    // Small supporting read change: load_stops embed adds pickup/delivery
    // city/state for the "City, ST -> City, ST" secondary line and route
    // search. Bounded to the same 500 recent loads; load_stops is indexed
    // by load_id.
    supabase
      .from("loads")
      .select(
        "id, load_number, brokers(company_name), customers(company_name), load_stops(stop_type, stop_sequence, city, state)"
      )
      .order("created_at", { ascending: false })
      .limit(LIST_LIMIT),
    supabase.from("brokers").select("id, company_name, mc_number").order("company_name").limit(LIST_LIMIT),
    supabase.from("customers").select("id, company_name, city, state").order("company_name").limit(LIST_LIMIT),
  ]);

  const entities: Record<NewDocumentEntityType, EntityOption[]> = {
    carrier: (carriers ?? []).map((c) => {
      const primary = c.dba_name ? `${c.legal_name} (${c.dba_name})` : c.legal_name;
      const secondary = joinDot([formatIdentifier("MC", c.mc_number), formatIdentifier("DOT", c.dot_number)]);
      return {
        id: c.id,
        primary,
        secondary,
        searchText: [c.legal_name, c.dba_name, c.mc_number, c.dot_number].filter(Boolean).join(" ").toLowerCase(),
      };
    }),
    driver: (drivers ?? []).map((d) => {
      const primary = `${d.first_name ?? ""} ${d.last_name ?? ""}`.trim() || "Driver";
      const secondary = d.cdl_number ? `CDL ${[d.cdl_state, d.cdl_number].filter(Boolean).join(" ")}` : null;
      return {
        id: d.id,
        primary,
        secondary,
        searchText: [d.first_name, d.last_name, d.cdl_number].filter(Boolean).join(" ").toLowerCase(),
      };
    }),
    load: ((loads ?? []) as unknown as {
      id: string;
      load_number: string;
      brokers: { company_name: string } | null;
      customers: { company_name: string } | null;
      load_stops: LoadStopLite[] | null;
    }[]).map((l) => {
      const party = l.brokers?.company_name ?? l.customers?.company_name ?? null;
      const stops = l.load_stops ?? [];
      const pickup = stops
        .filter((s) => s.stop_type === "pickup")
        .sort((a, b) => a.stop_sequence - b.stop_sequence)[0];
      const delivery = stops
        .filter((s) => s.stop_type === "delivery")
        .sort((a, b) => b.stop_sequence - a.stop_sequence)[0];
      const from = pickup ? cityState(pickup.city, pickup.state) : null;
      const to = delivery ? cityState(delivery.city, delivery.state) : null;
      const route = from && to ? `${from} → ${to}` : from ?? to ?? null;
      return {
        id: l.id,
        primary: l.load_number,
        secondary: party,
        tertiary: route,
        searchText: [l.load_number, party, from, to].filter(Boolean).join(" ").toLowerCase(),
      };
    }),
    broker: (brokers ?? []).map((b) => ({
      id: b.id,
      primary: b.company_name,
      secondary: formatIdentifier("MC", b.mc_number),
      searchText: [b.company_name, b.mc_number].filter(Boolean).join(" ").toLowerCase(),
    })),
    customer: (customers ?? []).map((c) => ({
      id: c.id,
      primary: c.company_name,
      secondary: cityState(c.city, c.state),
      searchText: [c.company_name, c.city, c.state].filter(Boolean).join(" ").toLowerCase(),
    })),
  };

  const initialEntityType =
    entity_type && NEW_DOCUMENT_ENTITY_TYPE_SET.has(entity_type)
      ? (entity_type as NewDocumentEntityType)
      : "";

  return (
    <div className="max-w-2xl">
      <AddDocumentRouter
        entities={entities}
        initialEntityType={initialEntityType}
        initialEntityId={initialEntityType ? entity_id : undefined}
      />
    </div>
  );
}
