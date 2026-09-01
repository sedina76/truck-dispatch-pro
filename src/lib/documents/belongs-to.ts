// Centralized "who owns this document" resolver for the global Documents
// library (/documents). ONE place that turns a raw
// documents.entity_type/entity_id pair into a business-readable owner --
// { category, displayName, secondaryIdentifier, href } -- instead of the
// table component re-deriving it with its own entity_type switch and
// printing raw enum strings like "Carrier_onboarding_application".
//
// EFFICIENCY -- never N+1. Callers pass the full (already bounded) page of
// documents; this groups them by entity_type and issues at most ONE
// batched `.in('id', [...])` lookup per distinct entity_type present, plus
// one extra lookup for the carriers that converted onboarding applications
// point at. Every lookup uses the caller's own RLS-scoped Supabase client,
// so a document whose owner lives in another tenant simply resolves as
// `unresolved` -- its name is never fetched across an organization
// boundary, and RLS is never weakened to resolve a name.
//
// Migration 0111 already re-points every ORDINARY onboarding-uploaded
// document (insurance, authority, W-9, ...) from
// entity_type='carrier_onboarding_application' onto entity_type='carrier'
// at conversion time, and deliberately leaves executed signed agreements
// attached to the application (governed by their own
// carrier_agreement_signings relationship + immutability guard). This
// resolver honours that: a still-onboarding applicant renders as
// "Carrier Applicant", a converted application's remaining rows resolve to
// the resulting carrier. Nothing here mutates a documents row.

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type DB = any;

export type BelongsTo = {
  category: string;
  displayName: string;
  secondaryIdentifier: string | null;
  href: string | null;
  /** entity_id points at nothing this user's org can see (dangling row,
   *  deleted parent, or cross-tenant) -- render as a muted fallback,
   *  never as a broken link. */
  unresolved: boolean;
};

export type DocumentOwnerRef = {
  id: string;
  entity_type: string;
  entity_id: string | null;
};

// entity_type -> human category label. Every value public.entity_type can
// hold that is actually used on public.documents in this app
// (broker_packet / carrier_w9 / integration are activity-feed-only enum
// values and never appear on a documents row).
const CATEGORY_LABEL: Record<string, string> = {
  carrier: "Carrier",
  carrier_onboarding_application: "Carrier Applicant",
  broker: "Broker",
  customer: "Customer",
  driver: "Driver",
  load: "Load",
  dispatch: "Dispatch",
  truck: "Truck",
  trailer: "Trailer",
  invoice: "Invoice",
  settlement: "Settlement",
  expense: "Expense",
  fuel: "Fuel",
  maintenance: "Maintenance",
  organization: "Organization",
};

// Category filter buttons for the library UI, and which entity_type(s)
// each one covers. "Loads" folds in dispatch-attached documents since a
// dispatch is just a load in motion. Kept here so the page query and the
// filter bar can never disagree on the mapping.
export const DOCUMENT_CATEGORY_FILTERS: { key: string; label: string; entityTypes: string[] }[] = [
  { key: "carriers", label: "Carriers", entityTypes: ["carrier"] },
  { key: "carrier_applicants", label: "Carrier Applicants", entityTypes: ["carrier_onboarding_application"] },
  { key: "drivers", label: "Drivers", entityTypes: ["driver"] },
  { key: "loads", label: "Loads", entityTypes: ["load", "dispatch"] },
  { key: "brokers", label: "Brokers", entityTypes: ["broker"] },
  { key: "customers", label: "Customers", entityTypes: ["customer"] },
];

export function entityTypesForCategoryKey(key: string | undefined | null): string[] | null {
  if (!key || key === "all") return null;
  return DOCUMENT_CATEGORY_FILTERS.find((c) => c.key === key)?.entityTypes ?? null;
}

function humanize(value: string | null | undefined): string {
  if (!value) return "";
  return value
    .split(/[_\s]+/)
    .filter(Boolean)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");
}

type TypeConfig = {
  table: string;
  columns: string;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  toDisplay: (row: any) => { displayName: string; secondaryIdentifier: string | null };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  href: (row: any) => string | null;
};

// One batched lookup is issued per key present in a given page of
// documents. columns are kept minimal; embedded relations
// (brokers(company_name) etc.) resolve in the same single round-trip.
const TYPE_CONFIG: Record<string, TypeConfig> = {
  carrier: {
    table: "carriers",
    columns: "id, legal_name, mc_number, dot_number",
    toDisplay: (r) => ({
      displayName: r.legal_name || "Carrier",
      secondaryIdentifier: r.mc_number ? `MC-${r.mc_number}` : r.dot_number ? `DOT-${r.dot_number}` : null,
    }),
    href: (r) => `/carriers/${r.id}`,
  },
  broker: {
    table: "brokers",
    columns: "id, company_name, mc_number",
    toDisplay: (r) => ({
      displayName: r.company_name || "Broker",
      secondaryIdentifier: r.mc_number ? `MC-${r.mc_number}` : null,
    }),
    href: (r) => `/brokers/${r.id}`,
  },
  customer: {
    table: "customers",
    columns: "id, company_name",
    toDisplay: (r) => ({ displayName: r.company_name || "Customer", secondaryIdentifier: null }),
    href: (r) => `/customers/${r.id}`,
  },
  driver: {
    table: "drivers",
    columns: "id, first_name, last_name, status",
    toDisplay: (r) => ({
      displayName: `${r.first_name ?? ""} ${r.last_name ?? ""}`.trim() || "Driver",
      secondaryIdentifier: r.status ? humanize(r.status) : null,
    }),
    href: (r) => `/drivers/${r.id}`,
  },
  load: {
    table: "loads",
    columns: "id, load_number, brokers(company_name), customers(company_name)",
    toDisplay: (r) => ({
      displayName: r.load_number || "Load",
      secondaryIdentifier: r.brokers?.company_name ?? r.customers?.company_name ?? null,
    }),
    href: (r) => `/loads/${r.id}`,
  },
  dispatch: {
    table: "dispatches",
    columns: "id, loads(load_number)",
    toDisplay: (r) => ({
      displayName: r.loads?.load_number ? `Dispatch · ${r.loads.load_number}` : "Dispatch",
      secondaryIdentifier: null,
    }),
    href: (r) => `/dispatch/${r.id}`,
  },
  truck: {
    table: "trucks",
    columns: "id, unit_number, make, model",
    toDisplay: (r) => ({
      displayName: r.unit_number ? `Unit ${r.unit_number}` : "Truck",
      secondaryIdentifier: [r.make, r.model].filter(Boolean).join(" ") || null,
    }),
    href: (r) => `/trucks/${r.id}`,
  },
  trailer: {
    table: "trailers",
    columns: "id, unit_number, trailer_type",
    toDisplay: (r) => ({
      displayName: r.unit_number ? `Trailer ${r.unit_number}` : "Trailer",
      secondaryIdentifier: r.trailer_type ? humanize(r.trailer_type) : null,
    }),
    href: (r) => `/trailers/${r.id}`,
  },
  invoice: {
    table: "invoices",
    columns: "id, invoice_number, bill_to_name",
    toDisplay: (r) => ({ displayName: r.invoice_number || "Invoice", secondaryIdentifier: r.bill_to_name ?? null }),
    href: (r) => `/invoices/${r.id}`,
  },
  settlement: {
    table: "settlements",
    columns: "id, settlement_number, carriers(legal_name)",
    toDisplay: (r) => ({
      displayName: r.settlement_number || "Settlement",
      secondaryIdentifier: r.carriers?.legal_name ?? null,
    }),
    href: (r) => `/settlements/${r.id}`,
  },
  expense: {
    table: "expenses",
    columns: "id, category, vendor_name",
    toDisplay: (r) => ({
      displayName: r.vendor_name || humanize(r.category) || "Expense",
      secondaryIdentifier: r.vendor_name ? humanize(r.category) : null,
    }),
    href: () => "/expenses",
  },
  fuel: {
    table: "fuel_logs",
    columns: "id, station_name, purchased_at",
    toDisplay: (r) => ({
      displayName: r.station_name || "Fuel purchase",
      secondaryIdentifier: r.purchased_at ? new Date(r.purchased_at).toLocaleDateString() : null,
    }),
    href: (r) => `/fuel/${r.id}`,
  },
  maintenance: {
    table: "maintenance_records",
    columns: "id, service_type, trucks(unit_number), trailers(unit_number)",
    toDisplay: (r) => ({
      displayName: humanize(r.service_type) || "Maintenance",
      secondaryIdentifier: r.trucks?.unit_number
        ? `Unit ${r.trucks.unit_number}`
        : r.trailers?.unit_number
          ? `Trailer ${r.trailers.unit_number}`
          : null,
    }),
    href: (r) => `/maintenance/${r.id}`,
  },
  organization: {
    table: "organizations",
    columns: "id, name",
    toDisplay: (r) => ({ displayName: r.name || "Organization", secondaryIdentifier: null }),
    href: () => "/settings",
  },
};

function unresolvedFor(entityType: string, entityId: string | null): BelongsTo {
  return {
    category: CATEGORY_LABEL[entityType] ?? humanize(entityType) ?? "Unknown",
    displayName: "Unlinked record",
    secondaryIdentifier: entityId ? `${humanize(entityType) || entityType} · ${entityId.slice(0, 8)}…` : humanize(entityType) || entityType,
    href: null,
    unresolved: true,
  };
}

/**
 * Resolve a page of documents to their business owners in a bounded number
 * of batched queries (one per distinct entity_type, plus one for converted
 * onboarding carriers). Returns a Map keyed by document id.
 */
export async function resolveDocumentOwners(
  supabase: DB,
  docs: DocumentOwnerRef[]
): Promise<Map<string, BelongsTo>> {
  const result = new Map<string, BelongsTo>();

  const idsByType = new Map<string, Set<string>>();
  for (const d of docs) {
    if (!d.entity_id) continue;
    if (!idsByType.has(d.entity_type)) idsByType.set(d.entity_type, new Set());
    idsByType.get(d.entity_type)!.add(d.entity_id);
  }

  // One batched lookup per standard entity_type present on this page.
  const rowsByType = new Map<string, Map<string, unknown>>();
  await Promise.all(
    [...idsByType.entries()].map(async ([type, ids]) => {
      const cfg = TYPE_CONFIG[type];
      if (!cfg) return;
      const { data } = await supabase.from(cfg.table).select(cfg.columns).in("id", [...ids]);
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      rowsByType.set(type, new Map((data ?? []).map((r: any) => [r.id, r])));
    })
  );

  // carrier_onboarding_application: resolve the applications, then a
  // second batched lookup for the carriers that converted ones point at.
  const appIds = idsByType.get("carrier_onboarding_application");
  const appRows = new Map<string, { id: string; legal_name: string | null; status: string; converted_carrier_id: string | null }>();
  const convertedCarriers = new Map<string, { id: string; legal_name: string | null; mc_number: string | null }>();
  if (appIds && appIds.size > 0) {
    const { data: apps } = await supabase
      .from("carrier_onboarding_applications")
      .select("id, legal_name, status, converted_carrier_id")
      .in("id", [...appIds]);
    for (const a of apps ?? []) appRows.set(a.id, a);
    const carrierIds = [...appRows.values()].map((a) => a.converted_carrier_id).filter((v): v is string => !!v);
    if (carrierIds.length > 0) {
      const { data: cs } = await supabase.from("carriers").select("id, legal_name, mc_number").in("id", carrierIds);
      for (const c of cs ?? []) convertedCarriers.set(c.id, c);
    }
  }

  for (const d of docs) {
    if (!d.entity_id) {
      result.set(d.id, unresolvedFor(d.entity_type, null));
      continue;
    }

    if (d.entity_type === "carrier_onboarding_application") {
      const app = appRows.get(d.entity_id);
      if (!app) {
        result.set(d.id, unresolvedFor(d.entity_type, d.entity_id));
        continue;
      }
      if (app.status === "converted" && app.converted_carrier_id) {
        const c = convertedCarriers.get(app.converted_carrier_id);
        result.set(d.id, {
          category: "Carrier",
          displayName: c?.legal_name || app.legal_name || "Carrier",
          secondaryIdentifier: c?.mc_number ? `MC-${c.mc_number}` : "Converted from applicant",
          href: `/carriers/${app.converted_carrier_id}`,
          unresolved: false,
        });
      } else {
        result.set(d.id, {
          category: "Carrier Applicant",
          displayName: app.legal_name || "Carrier Applicant",
          secondaryIdentifier: humanize(app.status) || "Onboarding",
          href: `/carriers/onboarding/${d.entity_id}`,
          unresolved: false,
        });
      }
      continue;
    }

    const cfg = TYPE_CONFIG[d.entity_type];
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const row = rowsByType.get(d.entity_type)?.get(d.entity_id) as any;
    if (!cfg || !row) {
      result.set(d.id, unresolvedFor(d.entity_type, d.entity_id));
      continue;
    }
    const { displayName, secondaryIdentifier } = cfg.toDisplay(row);
    result.set(d.id, {
      category: CATEGORY_LABEL[d.entity_type] ?? humanize(d.entity_type),
      displayName,
      secondaryIdentifier,
      href: cfg.href(row),
      unresolved: false,
    });
  }

  return result;
}
