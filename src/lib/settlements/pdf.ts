import "server-only";
import { PDFDocument, StandardFonts, rgb, type PDFPage, type PDFFont } from "pdf-lib";
import { createClient } from "@/lib/supabase/server";

const PAGE_WIDTH = 612; // US Letter, points
const PAGE_HEIGHT = 792;
const MARGIN = 54;

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}
function shortId(prefix: string, id: string): string {
  return `${prefix}-${id.slice(0, 8).toUpperCase()}`;
}

// ---------------------------------------------------------------------------
// Carrier Settlement -- same data/field boundary as the existing browser-
// print view (src/app/(app)/settlements/[id]/pdf/page.tsx), which this
// mirrors exactly. This is also the exact attachment the Send Carrier
// Settlement email path uses, so the same boundary comment applies here
// verbatim: this document must NEVER show customer/broker revenue,
// dispatch fee %, company margin, or an invoice total -- those are
// staff-only figures. No SSN/CDL/medical/HR data has a path into this
// query.
// ---------------------------------------------------------------------------
export async function renderCarrierSettlementPdf(settlementId: string): Promise<Uint8Array> {
  const supabase = await createClient();

  const { data: settlement, error } = await supabase
    .from("settlements")
    .select(
      "id, settlement_number, period_start, period_end, status, gross_amount, adjustments_amount, deductions_amount, advances_amount, quick_pay_enabled, quick_pay_rate_percent, quick_pay_fee_amount, net_amount, amount_paid, balance_due, organization_id, carrier_id, payee_name, carriers(legal_name, dba_name, mc_number, dot_number, phone, email)"
    )
    .eq("id", settlementId)
    .single();
  if (error || !settlement) throw new Error("Settlement not found.");
  const s = settlement as unknown as typeof settlement & {
    carriers: { legal_name: string; dba_name: string | null; mc_number: string | null; dot_number: string | null; phone: string | null; email: string | null } | null;
  };

  const [{ data: org }, { data: loadItemsRaw }, { data: otherItemsRaw }, { data: payments }] = await Promise.all([
    supabase
      .from("organizations")
      .select("name, mc_number, dot_number, business_phone, address_line1, city, state, postal_code")
      .eq("id", settlement.organization_id)
      .single(),
    supabase.from("settlement_line_items").select("*, dispatches(trucks(unit_number))").eq("settlement_id", settlementId).eq("item_type", "load_pay").order("delivery_date"),
    supabase.from("settlement_line_items").select("*").eq("settlement_id", settlementId).neq("item_type", "load_pay").order("created_at"),
    supabase.from("carrier_settlement_payments").select("*").eq("settlement_id", settlementId).eq("status", "posted").order("paid_date"),
  ]);

  type LoadItem = { id: string; load_number: string | null; delivery_date: string | null; carrier_rate: number | null; amount: number; dispatches: { trucks: { unit_number: string } | null } | null };
  type OtherItem = { id: string; item_type: string; description: string; amount: number; linked_fuel_log_id: string | null; linked_maintenance_id: string | null; linked_advance_id: string | null };
  const loadItems = (loadItemsRaw ?? []) as unknown as LoadItem[];
  const otherItems = (otherItemsRaw ?? []) as unknown as OtherItem[];
  const deductionItems = otherItems.filter((it) => it.item_type === "deduction");
  const advanceItems = otherItems.filter((it) => it.item_type === "advance" || it.linked_advance_id);
  const adjustmentItems = otherItems.filter((it) => it.item_type === "adjustment");
  const totalDeductions = deductionItems.reduce((sum, it) => sum + Number(it.amount), 0);
  const totalPaid = (payments ?? []).reduce((sum, p) => sum + Number(p.amount), 0);

  const pdf = await PDFDocument.create();
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  let page = pdf.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
  let y = PAGE_HEIGHT - MARGIN;
  const ensureRoom = (needed: number) => {
    if (y - needed < MARGIN) {
      page = pdf.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
      y = PAGE_HEIGHT - MARGIN;
    }
  };

  page.drawText(org?.name ?? "Your Company", { x: MARGIN, y, size: 14, font: bold });
  page.drawText("CARRIER SETTLEMENT", { x: PAGE_WIDTH - MARGIN - 220, y, size: 16, font: bold });
  y -= 14;
  const orgLine = [org?.address_line1, [org?.city, org?.state, org?.postal_code].filter(Boolean).join(", "), org?.business_phone].filter(Boolean).join(" -- ");
  if (orgLine) page.drawText(orgLine, { x: MARGIN, y, size: 8, font, color: rgb(0.45, 0.45, 0.45) });
  page.drawText(s.settlement_number, { x: PAGE_WIDTH - MARGIN - 220, y, size: 10, font: bold });
  y -= 12;
  page.drawText(
    `${new Date(s.period_start + "T00:00:00").toLocaleDateString()} - ${new Date(s.period_end + "T00:00:00").toLocaleDateString()}  --  ${s.status.replace(/_/g, " ").toUpperCase()}`,
    { x: PAGE_WIDTH - MARGIN - 220, y, size: 8.5, font, color: rgb(0.45, 0.45, 0.45) }
  );
  y -= 26;

  page.drawText("Carrier", { x: MARGIN, y, size: 8, font, color: rgb(0.5, 0.5, 0.5) });
  y -= 13;
  page.drawText(s.carriers?.dba_name || s.carriers?.legal_name || "--", { x: MARGIN, y, size: 10.5, font: bold });
  y -= 12;
  const carrierLine = [s.carriers?.mc_number && `MC# ${s.carriers.mc_number}`, s.carriers?.dot_number && `DOT# ${s.carriers.dot_number}`].filter(Boolean).join(" -- ");
  if (carrierLine) {
    page.drawText(carrierLine, { x: MARGIN, y, size: 8.5, font, color: rgb(0.45, 0.45, 0.45) });
    y -= 12;
  }
  if (s.payee_name) {
    page.drawText(`Paid to: ${s.payee_name}`, { x: MARGIN, y, size: 8.5, font, color: rgb(0.45, 0.45, 0.45) });
    y -= 12;
  }
  y -= 12;

  const cols = ["Load #", "Delivery", "Truck", "Carrier Pay"];
  const xs = [MARGIN, 220, 400, 480];
  cols.forEach((c, i) => page.drawText(c, { x: xs[i], y, size: 8, font: bold, color: rgb(0.3, 0.3, 0.3) }));
  y -= 6;
  page.drawLine({ start: { x: MARGIN, y }, end: { x: PAGE_WIDTH - MARGIN, y }, thickness: 0.5, color: rgb(0.75, 0.75, 0.75) });
  y -= 14;
  for (const it of loadItems) {
    ensureRoom(14);
    page.drawText(it.load_number ?? "--", { x: xs[0], y, size: 8.5, font });
    page.drawText(it.delivery_date ? new Date(it.delivery_date + "T00:00:00").toLocaleDateString() : "--", { x: xs[1], y, size: 8.5, font });
    page.drawText(it.dispatches?.trucks?.unit_number ?? "--", { x: xs[2], y, size: 8.5, font });
    page.drawText(money(it.carrier_rate ?? it.amount), { x: xs[3], y, size: 8.5, font: bold });
    y -= 14;
  }
  if (loadItems.length === 0) {
    page.drawText("No loads in this settlement.", { x: MARGIN, y, size: 9, font, color: rgb(0.5, 0.5, 0.5) });
    y -= 14;
  }
  y -= 6;
  page.drawLine({ start: { x: MARGIN, y: y + 10 }, end: { x: PAGE_WIDTH - MARGIN, y: y + 10 }, thickness: 0.5, color: rgb(0.75, 0.75, 0.75) });
  page.drawText("GROSS CARRIER PAY", { x: MARGIN, y, size: 10, font: bold });
  page.drawText(money(s.gross_amount), { x: 480, y, size: 10, font: bold });
  y -= 20;

  if (adjustmentItems.length > 0) {
    ensureRoom(20);
    page.drawText("Adjustments", { x: MARGIN, y, size: 8, font, color: rgb(0.5, 0.5, 0.5) });
    y -= 13;
    for (const it of adjustmentItems) {
      ensureRoom(13);
      page.drawText(it.description, { x: MARGIN, y, size: 8.5, font, color: rgb(0.3, 0.3, 0.3) });
      page.drawText(`${it.amount >= 0 ? "+" : ""}${money(it.amount)}`, { x: 480, y, size: 8.5, font });
      y -= 13;
    }
    y -= 6;
  }

  if (deductionItems.length > 0) {
    ensureRoom(20);
    page.drawText("Deductions", { x: MARGIN, y, size: 8, font, color: rgb(0.5, 0.5, 0.5) });
    y -= 13;
    for (const it of deductionItems) {
      ensureRoom(13);
      const label = it.linked_fuel_log_id
        ? `Fuel ${shortId("FL", it.linked_fuel_log_id)}`
        : it.linked_maintenance_id
          ? `Maintenance ${shortId("MNT", it.linked_maintenance_id)}`
          : it.description;
      page.drawText(label, { x: MARGIN, y, size: 8.5, font, color: rgb(0.3, 0.3, 0.3) });
      page.drawText(`-${money(Math.abs(it.amount))}`, { x: 480, y, size: 8.5, font });
      y -= 13;
    }
    page.drawText("TOTAL DEDUCTIONS", { x: MARGIN, y, size: 9, font: bold });
    page.drawText(`-${money(totalDeductions)}`, { x: 480, y, size: 9, font: bold });
    y -= 18;
  }

  if (advanceItems.length > 0) {
    ensureRoom(20);
    page.drawText("Advances", { x: MARGIN, y, size: 8, font, color: rgb(0.5, 0.5, 0.5) });
    y -= 13;
    for (const it of advanceItems) {
      ensureRoom(13);
      page.drawText(it.linked_advance_id ? `${shortId("ADV", it.linked_advance_id)} -- ${it.description}` : it.description, { x: MARGIN, y, size: 8.5, font, color: rgb(0.3, 0.3, 0.3) });
      page.drawText(`-${money(Math.abs(it.amount))}`, { x: 480, y, size: 8.5, font });
      y -= 13;
    }
    y -= 6;
  }

  if (s.quick_pay_enabled) {
    ensureRoom(16);
    page.drawText(`Quick Pay Fee (${s.quick_pay_rate_percent}%)`, { x: MARGIN, y, size: 8.5, font, color: rgb(0.4, 0.4, 0.4) });
    page.drawText(`-${money(s.quick_pay_fee_amount)}`, { x: 480, y, size: 8.5, font });
    y -= 18;
  }

  ensureRoom(24);
  page.drawLine({ start: { x: 340, y: y + 10 }, end: { x: PAGE_WIDTH - MARGIN, y: y + 10 }, thickness: 0.5, color: rgb(0.75, 0.75, 0.75) });
  page.drawText("NET CARRIER PAY", { x: 340, y, size: 12, font: bold });
  page.drawText(money(s.net_amount), { x: 480, y, size: 12, font: bold });
  y -= 24;

  if ((payments ?? []).length > 0) {
    ensureRoom(30 + (payments?.length ?? 0) * 13);
    page.drawText("Payment History", { x: MARGIN, y, size: 8, font, color: rgb(0.5, 0.5, 0.5) });
    y -= 13;
    for (const p of payments ?? []) {
      page.drawText(`${p.payment_number} -- ${new Date(p.paid_date + "T00:00:00").toLocaleDateString()} -- ${String(p.method).replace(/_/g, " ")}`, { x: MARGIN, y, size: 8.5, font, color: rgb(0.3, 0.3, 0.3) });
      page.drawText(money(p.amount), { x: 480, y, size: 8.5, font });
      y -= 13;
    }
    page.drawText("Total Paid", { x: MARGIN, y, size: 9, font: bold });
    page.drawText(money(totalPaid), { x: 480, y, size: 9, font: bold });
    y -= 18;
  }

  ensureRoom(20);
  if (s.status === "paid") {
    page.drawText("PAID IN FULL", { x: 340, y, size: 12, font: bold, color: rgb(0.06, 0.5, 0.35) });
  } else {
    page.drawText("Paid", { x: 340, y, size: 9, font, color: rgb(0.4, 0.4, 0.4) });
    page.drawText(money(s.amount_paid), { x: 480, y, size: 9, font });
    y -= 14;
    page.drawText("BALANCE DUE", { x: 340, y, size: 11, font: bold });
    page.drawText(money(s.balance_due), { x: 480, y, size: 11, font: bold });
  }

  return pdf.save();
}

// ---------------------------------------------------------------------------
// Driver Settlement -- same data/field boundary as the existing browser-
// print view (src/app/(app)/driver-settlements/[id]/pdf/page.tsx), which
// this mirrors exactly. Only settlement/load/org columns -- no path to
// SSN, CDL, medical, or any other driver HR data.
// ---------------------------------------------------------------------------
export async function renderDriverSettlementPdf(settlementId: string): Promise<Uint8Array> {
  const supabase = await createClient();

  const { data: settlement, error } = await supabase
    .from("driver_settlements")
    .select(
      "id, settlement_number, period_start, period_end, status, gross_pay, adjustments_amount, deductions_amount, advances_amount, net_pay, amount_paid, balance_due, organization_id, drivers(first_name, last_name), carriers(legal_name)"
    )
    .eq("id", settlementId)
    .single();
  if (error || !settlement) throw new Error("Settlement not found.");
  const s = settlement as unknown as typeof settlement & {
    drivers: { first_name: string; last_name: string } | null;
    carriers: { legal_name: string } | null;
  };

  const [{ data: org }, { data: items }, { data: adjustments }, { data: payments }] = await Promise.all([
    supabase
      .from("organizations")
      .select("name, mc_number, dot_number, business_phone, address_line1, city, state, postal_code")
      .eq("id", settlement.organization_id)
      .single(),
    supabase.from("driver_settlement_items").select("*").eq("driver_settlement_id", settlementId).order("delivery_date"),
    supabase.from("driver_settlement_adjustments").select("*").eq("driver_settlement_id", settlementId).order("effective_date"),
    supabase.from("driver_settlement_payments").select("*").eq("driver_settlement_id", settlementId).eq("status", "posted").order("paid_date"),
  ]);

  const driverName = s.drivers ? `${s.drivers.first_name} ${s.drivers.last_name}` : "--";

  const pdf = await PDFDocument.create();
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  let page = pdf.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
  let y = PAGE_HEIGHT - MARGIN;
  const ensureRoom = (needed: number) => {
    if (y - needed < MARGIN) {
      page = pdf.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
      y = PAGE_HEIGHT - MARGIN;
    }
  };

  page.drawText(org?.name ?? "Your Company", { x: MARGIN, y, size: 14, font: bold });
  page.drawText("DRIVER SETTLEMENT", { x: PAGE_WIDTH - MARGIN - 210, y, size: 16, font: bold });
  y -= 14;
  const orgLine = [org?.address_line1, [org?.city, org?.state, org?.postal_code].filter(Boolean).join(", "), org?.business_phone].filter(Boolean).join(" -- ");
  if (orgLine) page.drawText(orgLine, { x: MARGIN, y, size: 8, font, color: rgb(0.45, 0.45, 0.45) });
  page.drawText(s.settlement_number, { x: PAGE_WIDTH - MARGIN - 210, y, size: 10, font: bold });
  y -= 12;
  page.drawText(
    `${new Date(s.period_start + "T00:00:00").toLocaleDateString()} - ${new Date(s.period_end + "T00:00:00").toLocaleDateString()}  --  ${s.status.replace(/_/g, " ").toUpperCase()}`,
    { x: PAGE_WIDTH - MARGIN - 210, y, size: 8.5, font, color: rgb(0.45, 0.45, 0.45) }
  );
  y -= 26;

  page.drawText("Driver", { x: MARGIN, y, size: 8, font, color: rgb(0.5, 0.5, 0.5) });
  y -= 13;
  page.drawText(driverName, { x: MARGIN, y, size: 10.5, font: bold });
  y -= 12;
  if (s.carriers?.legal_name) {
    page.drawText(s.carriers.legal_name, { x: MARGIN, y, size: 8.5, font, color: rgb(0.45, 0.45, 0.45) });
    y -= 12;
  }
  y -= 12;

  const cols = ["Load #", "Delivery", "Miles", "Load Rate", "Driver Rate", "Gross Pay"];
  const xs = [MARGIN, 150, 260, 320, 400, 480];
  cols.forEach((c, i) => page.drawText(c, { x: xs[i], y, size: 8, font: bold, color: rgb(0.3, 0.3, 0.3) }));
  y -= 6;
  page.drawLine({ start: { x: MARGIN, y }, end: { x: PAGE_WIDTH - MARGIN, y }, thickness: 0.5, color: rgb(0.75, 0.75, 0.75) });
  y -= 14;
  for (const it of items ?? []) {
    ensureRoom(14);
    page.drawText(it.load_number ?? "--", { x: xs[0], y, size: 8.5, font });
    page.drawText(it.delivery_date ? new Date(it.delivery_date + "T00:00:00").toLocaleDateString() : "--", { x: xs[1], y, size: 8.5, font });
    page.drawText(it.miles ? Number(it.miles).toLocaleString() : "--", { x: xs[2], y, size: 8.5, font });
    page.drawText(money(it.load_rate), { x: xs[3], y, size: 8.5, font });
    page.drawText(it.pay_method === "percentage" ? `${it.pay_rate}%` : money(it.pay_rate), { x: xs[4], y, size: 8.5, font });
    page.drawText(money(it.gross_pay), { x: xs[5], y, size: 8.5, font: bold });
    y -= 14;
  }
  if ((items ?? []).length === 0) {
    page.drawText("No loads in this settlement.", { x: MARGIN, y, size: 9, font, color: rgb(0.5, 0.5, 0.5) });
    y -= 14;
  }
  y -= 8;

  if ((adjustments ?? []).length > 0) {
    ensureRoom(20 + (adjustments?.length ?? 0) * 13);
    page.drawText("Deductions / Advances / Adjustments", { x: MARGIN, y, size: 8, font, color: rgb(0.5, 0.5, 0.5) });
    y -= 13;
    for (const a of adjustments ?? []) {
      page.drawText(`${cap(a.bucket)} -- ${a.category}`, { x: MARGIN, y, size: 8.5, font, color: rgb(0.3, 0.3, 0.3) });
      const sign = a.bucket === "adjustment" && a.amount >= 0 ? "+" : "-";
      page.drawText(`${sign}${money(Math.abs(a.amount))}`, { x: 480, y, size: 8.5, font });
      y -= 13;
    }
    y -= 8;
  }

  ensureRoom(110);
  page.drawLine({ start: { x: 340, y: y + 10 }, end: { x: PAGE_WIDTH - MARGIN, y: y + 10 }, thickness: 0.5, color: rgb(0.75, 0.75, 0.75) });
  const summaryRow = (label: string, value: string, boldRow?: boolean) => {
    page.drawText(label, { x: 340, y, size: boldRow ? 11 : 9, font: boldRow ? bold : font, color: boldRow ? undefined : rgb(0.4, 0.4, 0.4) });
    page.drawText(value, { x: 480, y, size: boldRow ? 11 : 9, font: boldRow ? bold : font });
    y -= boldRow ? 16 : 13;
  };
  summaryRow("Gross Pay", money(s.gross_pay));
  summaryRow("Adjustments", money(s.adjustments_amount));
  summaryRow("Deductions", `-${money(s.deductions_amount)}`);
  summaryRow("Advances", `-${money(s.advances_amount)}`);
  summaryRow("NET PAY", money(s.net_pay), true);
  summaryRow("Paid", money(s.amount_paid));
  summaryRow("Balance Due", money(s.balance_due), true);

  if ((payments ?? []).length > 0) {
    ensureRoom(20 + (payments?.length ?? 0) * 12);
    y -= 6;
    page.drawText("Payment History", { x: MARGIN, y, size: 8, font, color: rgb(0.5, 0.5, 0.5) });
    y -= 12;
    for (const p of payments ?? []) {
      page.drawText(`${p.payment_number} -- ${new Date(p.paid_date + "T00:00:00").toLocaleDateString()} -- ${p.method} -- ${money(p.amount)}`, { x: MARGIN, y, size: 8, font, color: rgb(0.4, 0.4, 0.4) });
      y -= 12;
    }
  }

  return pdf.save();
}

function cap(s: string): string {
  return s.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

// Re-exported so callers don't need to know about pdf-lib's page/font types.
export type { PDFPage, PDFFont };
