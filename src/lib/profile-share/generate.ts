import "server-only";
import { PDFDocument, StandardFonts, rgb, type PDFPage, type PDFFont } from "pdf-lib";
import { createClient } from "@/lib/supabase/server";
import { getLatestDocument } from "@/lib/documents/latest-document";

const PAGE_WIDTH = 612; // US Letter, points
const PAGE_HEIGHT = 792;
const MARGIN = 50;

export type ExternalDriverProfile = {
  driver_id: string;
  full_name: string;
  phone: string | null;
  photo_url: string | null;
  status: string;
  cdl_class: string | null;
  cdl_state: string | null;
  cdl_expiry_date: string | null;
  cdl_endorsements: string | null;
  medical_card_expiry_date: string | null;
  years_experience: number | null;
  completed_trips: number;
};

export type ExternalCarrierProfile = {
  carrier_id: string;
  legal_name: string;
  dba_name: string | null;
  mc_number: string | null;
  dot_number: string | null;
  phone: string | null;
  email: string | null;
  address: string | null;
  is_active: boolean;
  auto_liability_status: "active" | "expired" | "missing";
  auto_liability_expiry: string | null;
  cargo_insurance_status: "active" | "expired" | "missing";
  cargo_insurance_expiry: string | null;
  completed_loads: number;
};

export type SafeDocumentRef = {
  id: string;
  document_type: string;
  label: string;
  sensitive: boolean;
};

export type LoadContext = {
  load_id: string;
  load_number: string;
  broker_name: string | null;
  origin: string | null;
  destination: string | null;
  pickup_scheduled: string | null;
  delivery_scheduled: string | null;
  truck_unit: string | null;
  trailer_unit: string | null;
};

export type ProfileShareData = {
  organization: { name: string; phone: string | null; email: string | null; address: string | null };
  load: LoadContext;
  driver: ExternalDriverProfile | null;
  carrier: ExternalCarrierProfile | null;
  includedDocuments: SafeDocumentRef[];
  generatedAt: string;
};

// Sensitive vs safe document allowlist for optional attachments (spec
// section 23). Sensitive types require explicit staff confirmation +
// owner/admin role -- also enforced at the DB level by
// guard_profile_share_org() (0042) so a crafted API call can't bypass it.
export const SAFE_DOCUMENT_TYPES = ["insurance_certificate", "motor_carrier_authority"] as const;
export const SENSITIVE_DOCUMENT_TYPES = ["cdl", "medical_card"] as const;

function complianceStatus(expiry: string | null): "valid" | "expiring_soon" | "expired" | "missing" {
  if (!expiry) return "missing";
  const days = (new Date(expiry + "T00:00:00").getTime() - Date.now()) / 86400000;
  if (days < 0) return "expired";
  if (days <= 30) return "expiring_soon";
  return "valid";
}

export { complianceStatus };

// Gathers everything the external profile needs -- entirely through the
// caller's own RLS-scoped session, and entirely through the two allowlist
// functions for driver/carrier data (spec section 21). Never a select(*)
// against drivers/carriers.
export async function computeProfileShareData(params: {
  loadId: string;
  includeDriverId: string | null;
  includeCarrierId: string | null;
  includeDocumentIds: string[];
}): Promise<ProfileShareData> {
  const supabase = await createClient();
  const { loadId, includeDriverId, includeCarrierId, includeDocumentIds } = params;

  const { data: load } = await supabase
    .from("loads")
    .select("id, load_number, organization_id, broker_id, customer_id, brokers(company_name), customers(company_name)")
    .eq("id", loadId)
    .single();
  if (!load) throw new Error("Load not found.");
  const loadRow = load as unknown as {
    id: string;
    load_number: string;
    organization_id: string;
    broker_id: string | null;
    customer_id: string | null;
    brokers: { company_name: string } | null;
    customers: { company_name: string } | null;
  };

  const [{ data: stops }, { data: dispatch }, { data: org }] = await Promise.all([
    supabase
      .from("load_stops")
      .select("stop_type, stop_sequence, city, state, scheduled_at")
      .eq("load_id", loadId)
      .order("stop_sequence"),
    supabase
      .from("dispatches")
      .select("id, truck_id, trailer_id, trucks(unit_number), trailers(unit_number)")
      .eq("load_id", loadId)
      .order("dispatched_at", { ascending: false })
      .limit(1)
      .maybeSingle(),
    supabase.from("organizations").select("name, business_phone, business_email, address_line1, city, state, postal_code").single(),
  ]);

  const pickup = (stops ?? []).filter((s) => s.stop_type === "pickup").sort((a, b) => a.stop_sequence - b.stop_sequence)[0];
  const delivery = (stops ?? []).filter((s) => s.stop_type === "delivery").sort((a, b) => b.stop_sequence - a.stop_sequence)[0];
  const dispatchRow = dispatch as unknown as {
    truck_id: string | null;
    trailer_id: string | null;
    trucks: { unit_number: string } | null;
    trailers: { unit_number: string } | null;
  } | null;

  const loadContext: LoadContext = {
    load_id: loadRow.id,
    load_number: loadRow.load_number,
    broker_name: loadRow.brokers?.company_name ?? loadRow.customers?.company_name ?? null,
    origin: pickup ? [pickup.city, pickup.state].filter(Boolean).join(", ") || null : null,
    destination: delivery ? [delivery.city, delivery.state].filter(Boolean).join(", ") || null : null,
    pickup_scheduled: pickup?.scheduled_at ?? null,
    delivery_scheduled: delivery?.scheduled_at ?? null,
    truck_unit: dispatchRow?.trucks?.unit_number ?? null,
    trailer_unit: dispatchRow?.trailers?.unit_number ?? null,
  };

  let driver: ExternalDriverProfile | null = null;
  if (includeDriverId) {
    const { data } = await supabase.rpc("get_external_driver_profile", { p_driver_id: includeDriverId }).maybeSingle();
    if (!data) throw new Error("Driver not found in your organization.");
    driver = data as ExternalDriverProfile;
  }

  let carrier: ExternalCarrierProfile | null = null;
  if (includeCarrierId) {
    const { data } = await supabase.rpc("get_external_carrier_profile", { p_carrier_id: includeCarrierId }).maybeSingle();
    if (!data) throw new Error("Carrier not found in your organization.");
    carrier = data as ExternalCarrierProfile;
  }

  const includedDocuments: SafeDocumentRef[] = [];
  if (includeDocumentIds.length > 0) {
    const { data: docs } = await supabase
      .from("documents")
      .select("id, document_type, file_name, entity_type, entity_id")
      .in("id", includeDocumentIds);
    for (const d of docs ?? []) {
      const sensitive = (SENSITIVE_DOCUMENT_TYPES as readonly string[]).includes(d.document_type);
      includedDocuments.push({ id: d.id, document_type: d.document_type, label: d.file_name, sensitive });
    }
  }

  return {
    organization: {
      name: org?.name ?? "Your Company",
      phone: org?.business_phone ?? null,
      email: org?.business_email ?? null,
      address: [org?.address_line1, org?.city, org?.state, org?.postal_code].filter(Boolean).join(", ") || null,
    },
    load: loadContext,
    driver,
    carrier,
    includedDocuments,
    generatedAt: new Date().toISOString(),
  };
}

// Finds the current safe-document candidates for a driver/carrier pair --
// used by the Share dialog to offer checkboxes. Returns at most one
// (latest) document per type, same "most recent wins" rule as everywhere
// else documents are surfaced (src/lib/documents/latest-document.ts).
export async function listSafeDocumentCandidates(
  driverId: string | null,
  carrierId: string | null
): Promise<SafeDocumentRef[]> {
  const supabase = await createClient();
  const out: SafeDocumentRef[] = [];

  if (carrierId) {
    for (const type of SAFE_DOCUMENT_TYPES) {
      const doc = await getLatestDocument(supabase, "carrier", carrierId, type);
      if (doc) out.push({ id: doc.id, document_type: type, label: labelForDocType(type), sensitive: false });
    }
  }
  if (driverId) {
    for (const type of SENSITIVE_DOCUMENT_TYPES) {
      const doc = await getLatestDocument(supabase, "driver", driverId, type);
      if (doc) out.push({ id: doc.id, document_type: type, label: labelForDocType(type), sensitive: true });
    }
  }
  return out;
}

function labelForDocType(type: string): string {
  const labels: Record<string, string> = {
    insurance_certificate: "Certificate of Insurance",
    motor_carrier_authority: "Carrier Authority",
    cdl: "CDL Copy",
    medical_card: "Medical Card",
  };
  return labels[type] ?? type;
}

// Frozen snapshot of exactly what was shared (spec section 13) -- stored
// verbatim in profile_share_log.snapshot. Deliberately a plain subset of
// ProfileShareData (same fields, no more) rather than the raw driver/
// carrier rows, so it can never accidentally carry a sensitive field that
// wasn't in the allowlist to begin with.
export function buildSnapshot(data: ProfileShareData) {
  return {
    load_number: data.load.load_number,
    broker_name: data.load.broker_name,
    origin: data.load.origin,
    destination: data.load.destination,
    pickup_scheduled: data.load.pickup_scheduled,
    delivery_scheduled: data.load.delivery_scheduled,
    truck_unit: data.load.truck_unit,
    trailer_unit: data.load.trailer_unit,
    driver: data.driver
      ? {
          name: data.driver.full_name,
          status: data.driver.status,
          cdl_class: data.driver.cdl_class,
          cdl_status: complianceStatus(data.driver.cdl_expiry_date),
          cdl_expiry: data.driver.cdl_expiry_date,
          medical_card_status: complianceStatus(data.driver.medical_card_expiry_date),
          medical_card_expiry: data.driver.medical_card_expiry_date,
          years_experience: data.driver.years_experience,
          completed_trips: data.driver.completed_trips,
        }
      : null,
    carrier: data.carrier
      ? {
          name: data.carrier.legal_name,
          mc_number: data.carrier.mc_number,
          dot_number: data.carrier.dot_number,
          auto_liability_status: data.carrier.auto_liability_status,
          cargo_insurance_status: data.carrier.cargo_insurance_status,
          completed_loads: data.carrier.completed_loads,
        }
      : null,
    included_document_ids: data.includedDocuments.map((d) => d.id),
    generated_at: data.generatedAt,
  };
}

function fmtDate(d: string | null): string {
  if (!d) return "--";
  return new Date(d + (d.length === 10 ? "T00:00:00" : "")).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

const STATUS_LABEL: Record<string, string> = {
  valid: "Valid",
  active: "Active",
  expiring_soon: "Expiring Soon",
  expired: "Expired",
  missing: "Not on File",
};

// Renders the professional PDF (spec section 5). No internal navigation/
// UI chrome -- this is a from-scratch pdf-lib document, not a screenshot
// of any app page. Only ever reads fields already present on
// ProfileShareData, which itself only ever came from the two allowlist
// RPCs plus load/stop/dispatch/org columns -- there is no code path here
// that could print an SSN, DOB, address, pay rate, settlement amount, or
// any other excluded field, because none of those fields exist on this
// type in the first place.
export async function renderProfileSharePdf(data: ProfileShareData): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);

  let page = pdf.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
  let y = PAGE_HEIGHT - MARGIN;

  const ensureRoom = (needed: number) => {
    if (y - needed < MARGIN + 30) {
      page = pdf.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
      y = PAGE_HEIGHT - MARGIN;
    }
  };

  // ---- Company header ------------------------------------------------------
  page.drawText(data.organization.name, { x: MARGIN, y, size: 15, font: bold });
  page.drawText("DRIVER / CARRIER PROFILE", { x: PAGE_WIDTH - MARGIN - 250, y, size: 15, font: bold, color: rgb(0.1, 0.1, 0.15) });
  y -= 15;
  const orgContact = [data.organization.address, data.organization.phone, data.organization.email].filter(Boolean).join("  |  ");
  if (orgContact) page.drawText(orgContact, { x: MARGIN, y, size: 8.5, font, color: rgb(0.45, 0.45, 0.45) });
  y -= 24;
  page.drawLine({ start: { x: MARGIN, y }, end: { x: PAGE_WIDTH - MARGIN, y }, thickness: 0.75, color: rgb(0.75, 0.75, 0.75) });
  y -= 20;

  // ---- Load information ------------------------------------------------------
  sectionHeading(page, y, bold, "Load Information");
  y -= 16;
  drawKV(page, y, font, bold, "Load #", data.load.load_number, "Broker / Customer", data.load.broker_name ?? "--");
  y -= 14;
  drawKV(page, y, font, bold, "Pickup", data.load.origin ?? "--", "Delivery", data.load.destination ?? "--");
  y -= 14;
  drawKV(
    page, y, font, bold,
    "Pickup Scheduled", data.load.pickup_scheduled ? new Date(data.load.pickup_scheduled).toLocaleString() : "--",
    "Delivery Scheduled", data.load.delivery_scheduled ? new Date(data.load.delivery_scheduled).toLocaleString() : "--"
  );
  y -= 24;

  // ---- Driver information ------------------------------------------------------
  if (data.driver) {
    ensureRoom(140);
    sectionHeading(page, y, bold, "Driver Information");
    y -= 16;
    drawKV(page, y, font, bold, "Driver Name", data.driver.full_name, "Status", cap(data.driver.status));
    y -= 14;
    if (data.driver.phone) {
      drawKV(page, y, font, bold, "Phone", data.driver.phone, "Years of Experience", data.driver.years_experience != null ? String(data.driver.years_experience) : "--");
      y -= 14;
    } else {
      drawKV(page, y, font, bold, "Years of Experience", data.driver.years_experience != null ? String(data.driver.years_experience) : "--", "Completed Trips", String(data.driver.completed_trips));
      y -= 14;
    }
    if (data.driver.phone) {
      drawKV(page, y, font, bold, "Completed Trips", String(data.driver.completed_trips), "", "");
      y -= 14;
    }
    y -= 8;
    page.drawText("CDL", { x: MARGIN, y, size: 9, font: bold, color: rgb(0.3, 0.3, 0.3) });
    y -= 13;
    drawKV(page, y, font, bold, "Class", data.driver.cdl_class ?? "--", "State", data.driver.cdl_state ?? "--");
    y -= 14;
    drawKV(page, y, font, bold, "Expiration", fmtDate(data.driver.cdl_expiry_date), "Endorsements", data.driver.cdl_endorsements ?? "None");
    y -= 24;
  }

  // ---- Carrier information ------------------------------------------------------
  if (data.carrier) {
    ensureRoom(140);
    sectionHeading(page, y, bold, "Carrier Information");
    y -= 16;
    drawKV(page, y, font, bold, "Carrier Name", data.carrier.legal_name, "DBA", data.carrier.dba_name ?? "--");
    y -= 14;
    drawKV(page, y, font, bold, "MC #", data.carrier.mc_number ?? "--", "DOT #", data.carrier.dot_number ?? "--");
    y -= 14;
    drawKV(page, y, font, bold, "Phone", data.carrier.phone ?? "--", "Email", data.carrier.email ?? "--");
    y -= 14;
    drawKV(page, y, font, bold, "Address", data.carrier.address ?? "--", "Status", data.carrier.is_active ? "Active" : "Inactive");
    y -= 14;
    drawKV(page, y, font, bold, "Completed Loads", String(data.carrier.completed_loads), "", "");
    y -= 24;
  }

  // ---- Equipment ------------------------------------------------------
  if (data.load.truck_unit || data.load.trailer_unit) {
    ensureRoom(60);
    sectionHeading(page, y, bold, "Equipment");
    y -= 16;
    drawKV(page, y, font, bold, "Truck Unit #", data.load.truck_unit ?? "--", "Trailer", data.load.trailer_unit ?? "--");
    y -= 24;
  }

  // ---- Compliance summary ------------------------------------------------------
  ensureRoom(100);
  sectionHeading(page, y, bold, "Compliance Summary");
  y -= 16;
  if (data.driver) {
    const cdlStatus = complianceStatus(data.driver.cdl_expiry_date);
    const medStatus = complianceStatus(data.driver.medical_card_expiry_date);
    drawComplianceRow(page, y, font, bold, "CDL", statusLine(cdlStatus, data.driver.cdl_expiry_date));
    y -= 14;
    drawComplianceRow(page, y, font, bold, "Medical Card", statusLine(medStatus, data.driver.medical_card_expiry_date));
    y -= 14;
  }
  if (data.carrier) {
    drawComplianceRow(page, y, font, bold, "Auto Liability Insurance", STATUS_LABEL[data.carrier.auto_liability_status]);
    y -= 14;
    drawComplianceRow(page, y, font, bold, "Cargo Insurance", STATUS_LABEL[data.carrier.cargo_insurance_status]);
    y -= 14;
  }
  y -= 10;

  // ---- Included documents note ------------------------------------------------------
  if (data.includedDocuments.length > 0) {
    ensureRoom(40);
    sectionHeading(page, y, bold, "Attached Documents");
    y -= 16;
    for (const doc of data.includedDocuments) {
      page.drawText(`- ${doc.label}`, { x: MARGIN, y, size: 9, font, color: rgb(0.3, 0.3, 0.3) });
      y -= 13;
    }
    y -= 8;
  }

  // ---- Contact information ------------------------------------------------------
  ensureRoom(50);
  sectionHeading(page, y, bold, "Contact Information");
  y -= 16;
  const contactBits = [data.organization.phone, data.organization.email].filter(Boolean).join("  |  ") || "--";
  page.drawText(contactBits, { x: MARGIN, y, size: 9.5, font });
  y -= 24;

  // ---- Footer on every page ------------------------------------------------------
  for (const p of pdf.getPages()) {
    p.drawText(`Generated by Truck Dispatch Pro  --  ${new Date(data.generatedAt).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" })}`, {
      x: MARGIN,
      y: MARGIN - 25,
      size: 7.5,
      font,
      color: rgb(0.55, 0.55, 0.55),
    });
  }

  return pdf.save();
}

function cap(s: string): string {
  return s.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

function statusLine(status: string, expiry: string | null): string {
  if (status === "missing") return "Not on File";
  const label = STATUS_LABEL[status] ?? cap(status);
  return expiry ? `${label} through ${fmtDate(expiry)}` : label;
}

function sectionHeading(page: PDFPage, y: number, bold: PDFFont, text: string) {
  page.drawText(text.toUpperCase(), { x: MARGIN, y, size: 10, font: bold, color: rgb(0.15, 0.15, 0.2) });
  page.drawLine({ start: { x: MARGIN, y: y - 4 }, end: { x: PAGE_WIDTH - MARGIN, y: y - 4 }, thickness: 0.5, color: rgb(0.85, 0.85, 0.85) });
}

function drawKV(page: PDFPage, y: number, font: PDFFont, bold: PDFFont, k1: string, v1: string, k2: string, v2: string) {
  if (k1) {
    page.drawText(`${k1}:`, { x: MARGIN, y, size: 8.5, font, color: rgb(0.45, 0.45, 0.45) });
    page.drawText(v1, { x: MARGIN + 95, y, size: 9.5, font: bold });
  }
  if (k2) {
    page.drawText(`${k2}:`, { x: MARGIN + 280, y, size: 8.5, font, color: rgb(0.45, 0.45, 0.45) });
    page.drawText(v2, { x: MARGIN + 375, y, size: 9.5, font: bold });
  }
}

function drawComplianceRow(page: PDFPage, y: number, font: PDFFont, bold: PDFFont, label: string, value: string) {
  page.drawText(`${label}:`, { x: MARGIN, y, size: 9.5, font, color: rgb(0.3, 0.3, 0.3) });
  page.drawText(value, { x: MARGIN + 160, y, size: 9.5, font: bold });
}
