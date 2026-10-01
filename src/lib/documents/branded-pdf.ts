// ---------------------------------------------------------------------------
// Branded PDF layouts for customer-facing billing documents: the freight
// invoice (standalone email attachment AND the invoice page inside the
// billing packet) and the customer/broker statement.
//
// Pure by design -- no "server-only", no Supabase, no "@/..." value imports
// -- so the exact same code that runs in production can be rendered and
// checked by `npm test` with fixture data (branded-pdf.test.mjs). Callers
// (src/lib/invoices/pdf.ts, src/lib/billing-packet/generate.ts,
// src/lib/statements/generate.ts) do the RLS-scoped fetching and hand the
// raw rows to the build*() functions here.
//
// pdf-lib's StandardFonts only encode WinAnsi. Every string that reaches
// drawText() goes through pdfSafe() first, so an emoji or an unusual
// character in a customer name can never crash invoice generation.
// ---------------------------------------------------------------------------
import { LineCapStyle, PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage, type RGB } from "pdf-lib";

export const PAGE_W = 612; // US Letter, points
export const PAGE_H = 792;
const ML = 42;
const MR = 42;
const MT = 36;
const MB = 30;
const CW = PAGE_W - ML - MR;
const FOOTER_H = 40;
const CONTENT_BOTTOM = PAGE_H - MB - FOOTER_H; // lowest "top" coordinate body content may reach

export const DEFAULT_ACCENT = "#1c54b8";

function hex(h: string): RGB {
  const m = /^#?([0-9a-f]{6})$/i.exec(h.trim());
  const n = m ? parseInt(m[1], 16) : parseInt(DEFAULT_ACCENT.slice(1), 16);
  return rgb(((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255);
}

const C = {
  ink: hex("#14202e"),
  text2: hex("#3e4c5f"),
  muted: hex("#526278"),
  border: hex("#c3ccd9"),
  rule: hex("#dde3ec"),
  headFill: hex("#eef2f8"),
  white: rgb(1, 1, 1),
  overdue: hex("#9a3412"),
  aging: [hex("#7ea2e6"), hex("#e0a43c"), hex("#b8410c"), hex("#6b1b1b")],
  empty: hex("#e6eaf0"),
};

// ---- Text safety & formatting ---------------------------------------------

const WINANSI_EXTRA = "\u20ac\u201a\u0192\u201e\u2026\u2020\u2021\u02c6\u2030\u0160\u2039\u0152\u017d\u2018\u2019\u201c\u201d\u2022\u2013\u2014\u02dc\u2122\u0161\u203a\u0153\u017e\u0178";

// Maps anything outside WinAnsi to a safe equivalent (or "?"), and folds the
// narrow no-break space Intl puts in "8:00 AM" -- otherwise drawText throws.
export function pdfSafe(input: unknown): string {
  const s = String(input ?? "")
    .normalize("NFC")
    .replace(/\r\n?/g, "\n")
    .replace(/[\t\u00a0\u2000-\u200a\u202f\u205f\u3000]/g, " ")
    .replace(/[\u2010-\u2012\u2212]/g, "-")
    .replace(/[\u2190-\u21ff]/g, "->");
  let out = "";
  for (const ch of s) {
    const c = ch.codePointAt(0) ?? 0;
    if (c > 0xffff || (c >= 0xfe00 && c <= 0xfe0f) || (c >= 0x200b && c <= 0x200d)) continue; // emoji & their joiners/variation selectors: drop
    if (ch === "\n" || (c >= 0x20 && c <= 0x7e) || (c >= 0xa1 && c <= 0xff) || WINANSI_EXTRA.includes(ch)) out += ch;
    else out += "?";
  }
  return out;
}

export function formatMoney(n: number | string | null | undefined, opts?: { symbol?: boolean }): string {
  const v = Number(n ?? 0);
  const abs = Math.abs(Number.isFinite(v) ? v : 0).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return `${v < 0 ? "-" : ""}${opts?.symbol === false ? "" : "$"}${abs}`;
}

// "2026-09-24" -> "Sep 24, 2026". Date-only strings are calendar dates, so
// they're formatted in UTC -- never shifted a day by the server's zone.
export function formatDate(d: string | null | undefined): string {
  if (!d) return "--";
  const iso = /^\d{4}-\d{2}-\d{2}$/.test(d) ? `${d}T00:00:00Z` : d;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return String(d);
  return new Intl.DateTimeFormat("en-US", { timeZone: "UTC", month: "short", day: "numeric", year: "numeric" }).format(date);
}

function formatQty(n: number | string | null | undefined): string {
  const v = Number(n ?? 0);
  return v.toLocaleString("en-US", { maximumFractionDigits: 2 });
}

export function termsLabel(issueDate: string | null, dueDate: string | null): string | null {
  if (!issueDate || !dueDate) return null;
  const days = Math.round((Date.parse(`${dueDate}T00:00:00Z`) - Date.parse(`${issueDate}T00:00:00Z`)) / 86_400_000);
  if (!Number.isFinite(days) || days < 0) return null;
  return days === 0 ? "Due on receipt" : `Net ${days}`;
}

function humanize(s: string | null | undefined): string | null {
  if (!s) return null;
  return s.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

function joinNonEmpty(parts: (string | null | undefined)[], sep: string): string | null {
  const j = parts.map((p) => (p == null ? "" : String(p).trim())).filter(Boolean).join(sep);
  return j || null;
}

function cityStateZip(city?: string | null, state?: string | null, zip?: string | null): string | null {
  const cs = joinNonEmpty([city, state], ", ");
  return joinNonEmpty([cs, zip], " ");
}

function splitLines(s: string | null | undefined, max: number): string[] {
  if (!s) return [];
  return s
    .split(/\n|;\s*/)
    .map((l) => l.trim())
    .filter(Boolean)
    .slice(0, max);
}

// ---- Low-level drawing (all positions measured from the TOP of the page) --

export type BrandFonts = { reg: PDFFont; bold: PDFFont };

export async function embedBrandFonts(pdf: PDFDocument): Promise<BrandFonts> {
  return { reg: await pdf.embedFont(StandardFonts.Helvetica), bold: await pdf.embedFont(StandardFonts.HelveticaBold) };
}

function textWidth(s: string, font: PDFFont, size: number, spacing = 0): number {
  const t = pdfSafe(s);
  if (!spacing) return font.widthOfTextAtSize(t, size);
  // Letter-spaced text is drawn glyph by glyph, so measure it the same way
  // (whole-string widths come out narrower and right-aligned labels overshoot).
  const chars = [...t];
  return chars.reduce((w, ch) => w + font.widthOfTextAtSize(ch, size), 0) + spacing * Math.max(0, chars.length - 1);
}

type TextOpts = { size: number; font: PDFFont; color?: RGB; align?: "left" | "right" | "center"; spacing?: number; maxWidth?: number };

// Draws one line with its baseline `baseline` points below the page top.
function drawLine1(page: PDFPage, raw: string, x: number, baseline: number, o: TextOpts): number {
  let s = pdfSafe(raw).replace(/\n/g, " ");
  if (o.maxWidth != null) s = fit(s, o.font, o.size, o.maxWidth, o.spacing);
  const w = textWidth(s, o.font, o.size, o.spacing);
  const left = o.align === "right" ? x - w : o.align === "center" ? x - w / 2 : x;
  const color = o.color ?? C.ink;
  const y = PAGE_H - baseline;
  if (o.spacing) {
    let cx = left;
    for (const ch of s) {
      page.drawText(ch, { x: cx, y, size: o.size, font: o.font, color });
      cx += o.font.widthOfTextAtSize(ch, o.size) + o.spacing;
    }
  } else if (s) {
    page.drawText(s, { x: left, y, size: o.size, font: o.font, color });
  }
  return w;
}

function fit(s: string, font: PDFFont, size: number, maxWidth: number, spacing = 0): string {
  if (textWidth(s, font, size, spacing) <= maxWidth) return s;
  let lo = 0;
  let hi = s.length;
  while (lo < hi) {
    const mid = Math.ceil((lo + hi) / 2);
    if (textWidth(s.slice(0, mid) + "…", font, size, spacing) <= maxWidth) lo = mid;
    else hi = mid - 1;
  }
  return s.slice(0, lo).trimEnd() + "…";
}

export function wrapText(raw: string, font: PDFFont, size: number, maxWidth: number): string[] {
  const lines: string[] = [];
  for (const para of pdfSafe(raw).split("\n")) {
    let line = "";
    for (const word of para.split(/ +/).filter(Boolean)) {
      const test = line ? `${line} ${word}` : word;
      if (font.widthOfTextAtSize(test, size) <= maxWidth) {
        line = test;
        continue;
      }
      if (line) lines.push(line);
      // A single word wider than the column (a long reference number) is
      // broken by characters rather than overflowing into the next column.
      let w = word;
      while (font.widthOfTextAtSize(w, size) > maxWidth && w.length > 1) {
        let cut = w.length - 1;
        while (cut > 1 && font.widthOfTextAtSize(w.slice(0, cut), size) > maxWidth) cut--;
        lines.push(w.slice(0, cut));
        w = w.slice(cut);
      }
      line = w;
    }
    lines.push(line);
  }
  while (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();
  return lines;
}

type Corners = [number, number, number, number]; // tl, tr, br, bl

function box(page: PDFPage, x: number, top: number, w: number, h: number, o: { radius?: number | Corners; fill?: RGB; stroke?: RGB; strokeWidth?: number; dash?: number[] }) {
  const r = typeof o.radius === "number" || o.radius == null ? ([o.radius ?? 0, o.radius ?? 0, o.radius ?? 0, o.radius ?? 0] as Corners) : o.radius;
  const [tl, tr, br, bl] = r.map((v) => Math.max(0, Math.min(v, w / 2, h / 2))) as Corners;
  const arc = (rad: number, ex: number, ey: number) => (rad > 0 ? `A ${rad} ${rad} 0 0 1 ${ex} ${ey} ` : `L ${ex} ${ey} `);
  const path =
    `M ${tl} 0 L ${w - tr} 0 ${arc(tr, w, tr)}` +
    `L ${w} ${h - br} ${arc(br, w - br, h)}` +
    `L ${bl} ${h} ${arc(bl, 0, h - bl)}` +
    `L 0 ${tl} ${arc(tl, tl, 0)}Z`;
  page.drawSvgPath(path, {
    x,
    y: PAGE_H - top,
    color: o.fill,
    borderColor: o.stroke,
    borderWidth: o.stroke ? (o.strokeWidth ?? 0.75) : undefined,
    borderDashArray: o.dash,
  });
}

function hline(page: PDFPage, x1: number, x2: number, top: number, color: RGB, thickness = 0.75, dash?: number[]) {
  page.drawLine({ start: { x: x1, y: PAGE_H - top }, end: { x: x2, y: PAGE_H - top }, thickness, color, dashArray: dash });
}

const TRUCK_ICON =
  "M3 7h11v9H3z M14 10h4l3 3v3h-7 " +
  "M8.8 17.5 A1.8 1.8 0 1 1 5.2 17.5 A1.8 1.8 0 1 1 8.8 17.5 " +
  "M18.8 17.5 A1.8 1.8 0 1 1 15.2 17.5 A1.8 1.8 0 1 1 18.8 17.5";

function drawLogo(page: PDFPage, x: number, top: number, accent: RGB) {
  box(page, x, top, 39, 39, { radius: 7.5, fill: accent });
  const scale = 22.5 / 24;
  page.drawSvgPath(TRUCK_ICON, {
    x: x + 8.25,
    y: PAGE_H - (top + 8.25),
    scale,
    borderColor: C.white,
    borderWidth: 1.8,
    borderLineCap: LineCapStyle.Round,
  });
}

function sectionLabel(page: PDFPage, f: BrandFonts, s: string, x: number, baseline: number, align: "left" | "right" = "left", color: RGB = C.muted, maxWidth?: number) {
  return drawLine1(page, s.toUpperCase(), x, baseline, { size: 8.25, font: f.bold, color, spacing: 0.8, align, maxWidth });
}

// ---- Shared header -----------------------------------------------------------

export type DocOrg = {
  name: string;
  address: string | null; // one line, "123 Main St · Dallas, TX 75201"
  contact: string | null; // "(555) 555-0100 · billing@acme.com"
  authority: string | null; // "MC 123456 · USDOT 1234567"
  footer: string | null; // organizations.invoice_footer
};

function drawHeader(page: PDFPage, f: BrandFonts, accent: RGB, org: DocOrg, title: string, grid: [string, string, boolean?][]): number {
  // Right block first, so the left block knows how much width it has.
  const titleBase = MT + 17;
  drawLine1(page, title, PAGE_W - MR, titleBase, { size: 22.5, font: f.bold, color: accent, spacing: 1.8, align: "right" });
  const gSize = 9.4;
  const valW = Math.max(60, ...grid.map(([, v, b]) => textWidth(v, b ? f.bold : f.reg, gSize)));
  const labW = Math.max(...grid.map(([l]) => textWidth(l, f.reg, gSize)), 0);
  const valX = PAGE_W - MR - valW;
  const labX = valX - 12 - labW;
  let gBase = titleBase + 19;
  for (const [l, v, b] of grid) {
    drawLine1(page, l, labX, gBase, { size: gSize, font: f.reg, color: C.muted });
    drawLine1(page, v, valX, gBase, { size: gSize, font: b ? f.bold : f.reg, color: C.ink });
    gBase += 12.5;
  }
  const rightBottom = gBase - 12.5 + 4;

  drawLogo(page, ML, MT, accent);
  const lx = ML + 39 + 10.5;
  const lMax = labX - 18 - lx;
  let base = MT + 13;
  drawLine1(page, org.name, lx, base, { size: 15, font: f.bold, maxWidth: lMax });
  base += 4;
  for (const line of [org.address, org.contact, org.authority]) {
    if (!line) continue;
    base += 13.5;
    drawLine1(page, line, lx, base, { size: 9.4, font: f.reg, color: C.text2, maxWidth: lMax });
  }
  const leftBottom = Math.max(base + 4, MT + 39);

  const ruleTop = Math.max(leftBottom, rightBottom) + 14;
  box(page, ML, ruleTop, CW, 3, { radius: 1.5, fill: accent });
  return ruleTop + 3 + 15;
}

// Compact header for overflow pages: name on the left, "INVOICE INV-1041
// (continued)" on the right, thin accent rule.
function drawContinuationHeader(page: PDFPage, f: BrandFonts, accent: RGB, orgName: string, right: string): number {
  drawLine1(page, orgName, ML, MT + 12, { size: 11, font: f.bold, maxWidth: CW / 2 });
  drawLine1(page, right, PAGE_W - MR, MT + 12, { size: 9.4, font: f.bold, color: accent, align: "right", spacing: 0.4 });
  box(page, ML, MT + 22, CW, 2, { radius: 1, fill: accent });
  return MT + 22 + 2 + 15;
}

function drawFooters(pages: PDFPage[], f: BrandFonts, left: (string | null)[], leftBold: string | null, pageNumbers = true) {
  pages.forEach((page, i) => {
    const top = PAGE_H - MB - 30;
    hline(page, ML, PAGE_W - MR, top, C.rule);
    let base = top + 14;
    if (leftBold) {
      drawLine1(page, leftBold, ML, base, { size: 9, font: f.bold, color: C.ink, maxWidth: CW - 90 });
      base += 11.5;
    }
    const rest = left.filter(Boolean).join(" ");
    if (rest) drawLine1(page, rest, ML, base, { size: 8.6, font: f.reg, color: C.muted, maxWidth: CW - 90 });
    if (pageNumbers) drawLine1(page, `Page ${i + 1} of ${pages.length}`, PAGE_W - MR, base, { size: 8.6, font: f.reg, color: C.muted, align: "right" });
  });
}

function orgFromRow(org: OrgRow | null): DocOrg {
  const authority = joinNonEmpty([org?.mc_number ? `MC ${org.mc_number}` : null, org?.dot_number ? `USDOT ${org.dot_number}` : null], " · ");
  return {
    name: org?.name?.trim() || "Your Company",
    address: joinNonEmpty([org?.address_line1, cityStateZip(org?.city, org?.state, org?.postal_code)], " · "),
    contact: joinNonEmpty([org?.business_phone, org?.business_email], " · "),
    authority,
    footer: org?.invoice_footer?.trim() || null,
  };
}

// Where a customer should mail/send money when the invoice is NOT factored:
// the org's explicit remittance instructions if it has them, otherwise its
// mailing address, otherwise its physical address.
function orgRemitLines(org: OrgRow | null): string[] {
  const explicit = splitLines(org?.remittance_instructions, 3);
  if (explicit.length) return explicit;
  const mail = joinNonEmpty([org?.mailing_address_line1, cityStateZip(org?.mailing_city, org?.mailing_state, org?.mailing_postal_code)], "\n");
  if (mail) return mail.split("\n");
  const phys = joinNonEmpty([org?.address_line1, cityStateZip(org?.city, org?.state, org?.postal_code)], "\n");
  return phys ? phys.split("\n") : [];
}

export type OrgRow = {
  name?: string | null;
  mc_number?: string | null;
  dot_number?: string | null;
  business_phone?: string | null;
  business_email?: string | null;
  address_line1?: string | null;
  city?: string | null;
  state?: string | null;
  postal_code?: string | null;
  mailing_address_line1?: string | null;
  mailing_city?: string | null;
  mailing_state?: string | null;
  mailing_postal_code?: string | null;
  remittance_instructions?: string | null;
  invoice_footer?: string | null;
};

// =============================================================================
// INVOICE
// =============================================================================

export type InvoiceSource = {
  invoice: {
    invoice_number: string;
    issue_date: string | null;
    due_date: string | null;
    bill_to_name: string | null;
    bill_to_email?: string | null;
    bill_to_address?: string | null;
    subtotal_amount: number | string | null;
    discount_amount?: number | string | null;
    tax_amount?: number | string | null;
    total_amount: number | string | null;
    amount_paid?: number | string | null;
    balance_due: number | string | null;
    notes?: string | null;
  };
  org: OrgRow | null;
  lineItems: { description: string | null; quantity: number | string | null; unit_price: number | string | null; line_total: number | string | null }[];
  load: {
    load_number: string | null;
    total_miles?: number | string | null;
    equipment_type?: string | null;
    weight_lbs?: number | string | null;
    rate_confirmation_number?: string | null;
    stops?: {
      stop_type: string;
      stop_sequence?: number | null;
      facility_name: string | null;
      city: string | null;
      state: string | null;
      scheduled_at: string | null;
      timezone?: string | null;
      reference_number?: string | null;
    }[];
  } | null;
  driverName?: string | null;
  truckUnit?: string | null;
  // Set when the invoice has a live factoring submission (anything but
  // rejected/cancelled): payment must go to the factor, and the invoice
  // carries a Notice of Assignment.
  factoring?: {
    companyName: string;
    remittanceInstructions: string | null;
    address: string | null;
    phone: string | null;
    email: string | null;
  } | null;
  // Billing packet only: what's actually attached behind this page.
  documentsIncluded?: string[] | null;
  // Stop appointment formatter (the server passes one that resolves each
  // stop's own timezone); defaults to a date-only UTC render.
  formatStopTime?: (iso: string | null, timezone: string | null) => string;
  accent?: string;
};

export type InvoiceDoc = {
  accent: string;
  org: DocOrg;
  number: string;
  grid: [string, string, boolean?][];
  billTo: { name: string; lines: string[] };
  remitTo: { name: string; lines: string[] };
  references: [string, string][];
  route: null | {
    pickup: { name: string; place: string | null; when: string | null } | null;
    delivery: { name: string; place: string | null; when: string | null } | null;
    middleTop: string | null;
    middleBottom: string | null;
  };
  lines: { description: string; qty: string; rate: string; amount: string }[];
  totals: [string, string][];
  totalDue: string;
  documentsIncluded: string[];
  notes: string | null;
  noa: null | { factorName: string; body: string };
  footerReminder: string;
};

// Pure: raw rows in, display-ready strings out. Everything the layout shows
// is decided here, so the decisions are unit-testable without drawing.
export function buildInvoiceDoc(src: InvoiceSource): InvoiceDoc {
  const inv = src.invoice;
  const org = orgFromRow(src.org);
  const fmtStop = src.formatStopTime ?? ((iso: string | null) => (iso ? formatDate(iso.slice(0, 10)) : ""));

  const grid: InvoiceDoc["grid"] = [
    ["Invoice #", inv.invoice_number, true],
    ["Invoice date", formatDate(inv.issue_date)],
    ["Due date", formatDate(inv.due_date), true],
  ];
  const terms = termsLabel(inv.issue_date, inv.due_date);
  if (terms) grid.push(["Terms", terms]);
  if (src.load?.load_number) grid.push(["Load #", src.load.load_number, true]);

  const billLines = [...splitLines(inv.bill_to_address, 3), ...(inv.bill_to_email ? [inv.bill_to_email] : [])];

  const f = src.factoring ?? null;
  const factorLines = f ? (splitLines(f.remittanceInstructions, 3).length ? splitLines(f.remittanceInstructions, 3) : splitLines(f.address, 3)) : [];
  const remitTo = f
    ? { name: f.companyName, lines: [...factorLines, `Ref: ${org.name}`] }
    : { name: org.name, lines: [...orgRemitLines(src.org), `Ref: ${inv.invoice_number}`] };

  const stops = [...(src.load?.stops ?? [])].sort((a, b) => (a.stop_sequence ?? 0) - (b.stop_sequence ?? 0));
  const pickups = stops.filter((s) => s.stop_type === "pickup");
  const deliveries = stops.filter((s) => s.stop_type === "delivery");
  const pickup = pickups[0] ?? null;
  const delivery = deliveries[deliveries.length - 1] ?? null;

  const references: [string, string][] = [];
  if (src.load?.rate_confirmation_number) references.push(["Rate con", src.load.rate_confirmation_number]);
  if (pickup?.reference_number) references.push(["Pickup #", pickup.reference_number]);
  if (delivery?.reference_number) references.push(["Delivery #", delivery.reference_number]);
  if (src.driverName) references.push(["Driver", src.driverName]);
  if (src.truckUnit) references.push(["Truck", `Unit ${src.truckUnit}`]);

  const stopView = (s: (typeof stops)[number] | null) =>
    s ? { name: s.facility_name?.trim() || cityStateZip(s.city, s.state) || "--", place: s.facility_name?.trim() ? cityStateZip(s.city, s.state) : null, when: s.scheduled_at ? fmtStop(s.scheduled_at, s.timezone ?? null) : null } : null;
  const miles = Number(src.load?.total_miles ?? 0);
  const weight = Number(src.load?.weight_lbs ?? 0);
  const route =
    pickup || delivery
      ? {
          pickup: stopView(pickup),
          delivery: stopView(delivery),
          middleTop: joinNonEmpty([miles > 0 ? `${formatQty(miles)} mi` : null, stops.length > 2 ? `${stops.length} stops` : null], " · "),
          middleBottom: joinNonEmpty([humanize(src.load?.equipment_type), weight > 0 ? `${formatQty(weight)} lb` : null], " · "),
        }
      : null;

  const num = (v: unknown) => Number(v ?? 0) || 0;
  const totals: [string, string][] = [["Subtotal", formatMoney(inv.subtotal_amount)]];
  if (num(inv.discount_amount) > 0) totals.push(["Discount", formatMoney(-num(inv.discount_amount))]);
  if (num(inv.tax_amount) > 0) totals.push(["Tax", formatMoney(inv.tax_amount)]);
  if (num(inv.discount_amount) > 0 || num(inv.tax_amount) > 0) totals.push(["Invoice total", formatMoney(inv.total_amount)]);
  totals.push(["Payments & credits", num(inv.amount_paid) > 0 ? formatMoney(-num(inv.amount_paid)) : formatMoney(0)]);

  const noa = f
    ? {
        factorName: f.companyName,
        body:
          `This account has been assigned to and must be paid only to ${f.companyName}` +
          (factorLines.length ? `, ${factorLines.join(", ")}` : "") +
          ". Payment to any other party will not satisfy this obligation." +
          (f.phone || f.email ? ` Questions: ${joinNonEmpty([f.phone, f.email], " · ")}.` : ""),
      }
    : null;

  return {
    accent: src.accent ?? DEFAULT_ACCENT,
    org,
    number: inv.invoice_number,
    grid,
    billTo: { name: inv.bill_to_name?.trim() || "--", lines: billLines },
    remitTo,
    references,
    route,
    lines: src.lineItems.map((li) => ({
      description: li.description ?? "",
      qty: formatQty(li.quantity),
      rate: formatMoney(li.unit_price, { symbol: false }),
      amount: formatMoney(li.line_total, { symbol: false }),
    })),
    totals,
    totalDue: formatMoney(inv.balance_due),
    documentsIncluded: src.documentsIncluded ?? [],
    notes: inv.notes?.trim() || null,
    noa,
    footerReminder: `Please include invoice # ${inv.invoice_number} with your payment.`,
  };
}

// Draws the invoice starting on a fresh page from `newPage()` (one page in
// practice; long charge lists continue onto more pages with a repeated
// table header). Returns the pages it drew on.
export function drawInvoice(doc: InvoiceDoc, f: BrandFonts, newPage: () => PDFPage): PDFPage[] {
  const accent = hex(doc.accent);
  const pages: PDFPage[] = [];
  let page = newPage();
  pages.push(page);
  let top = drawHeader(page, f, accent, doc.org, "INVOICE", doc.grid);

  // ---- Bill to / Remit to / References -----------------------------------
  const colW = (CW - 30) / 3;
  const colX = [ML, ML + colW + 15, ML + 2 * (colW + 15)];
  const blockTop = top;
  const party = (x: number, label: string, p: { name: string; lines: string[] }) => {
    sectionLabel(page, f, label, x, blockTop + 7);
    let b = blockTop + 7 + 15;
    const nameLines = wrapText(p.name, f.bold, 10.5, colW).slice(0, 2);
    for (const nl of nameLines) {
      drawLine1(page, nl, x, b, { size: 10.5, font: f.bold });
      b += 13;
    }
    for (const l of p.lines) {
      drawLine1(page, l, x, b, { size: 9.4, font: f.reg, color: C.text2, maxWidth: colW });
      b += 12.5;
    }
    return b;
  };
  const b1 = party(colX[0], "Bill to", doc.billTo);
  const b2 = party(colX[1], "Remit payment to", doc.remitTo);
  sectionLabel(page, f, "References", colX[2], blockTop + 7);
  let b3 = blockTop + 7 + 15;
  if (doc.references.length === 0) {
    drawLine1(page, "--", colX[2], b3, { size: 9.4, font: f.reg, color: C.muted });
    b3 += 12.5;
  } else {
    const rLabW = Math.max(...doc.references.map(([l]) => textWidth(l, f.reg, 9.4)));
    for (const [l, v] of doc.references) {
      drawLine1(page, l, colX[2], b3, { size: 9.4, font: f.reg, color: C.muted });
      drawLine1(page, v, colX[2] + rLabW + 9, b3, { size: 9.4, font: f.reg, maxWidth: colW - rLabW - 9 });
      b3 += 12.5;
    }
  }
  top = Math.max(b1, b2, b3) - 8 + 15;

  // ---- Route strip ---------------------------------------------------------
  if (doc.route) {
    const r = doc.route;
    const h = 70;
    box(page, ML, top, CW, h, { radius: 7.5, stroke: C.border, strokeWidth: 0.75 });
    const innerL = ML + 13.5;
    const innerR = PAGE_W - MR - 13.5;
    const midW = 128;
    const sideW = (innerR - innerL - midW - 24) / 2;
    const midCx = (innerL + innerR) / 2;
    const labelBase = top + 12 + 8;

    if (r.pickup) {
      page.drawCircle({ x: innerL + 3.75, y: PAGE_H - (labelBase - 3), size: 3, borderColor: accent, borderWidth: 1.5 });
      sectionLabel(page, f, "Pickup", innerL + 13.5, labelBase);
      let b = labelBase + 15;
      drawLine1(page, r.pickup.name, innerL, b, { size: 10.5, font: f.bold, maxWidth: sideW });
      for (const l of [r.pickup.place, r.pickup.when]) {
        if (!l) continue;
        b += 12.5;
        drawLine1(page, l, innerL, b, { size: 9.4, font: f.reg, color: C.text2, maxWidth: sideW });
      }
    }
    if (r.delivery) {
      page.drawCircle({ x: innerR - 3.75, y: PAGE_H - (labelBase - 3), size: 3.75, color: accent });
      sectionLabel(page, f, "Delivery", innerR - 13.5, labelBase, "right");
      let b = labelBase + 15;
      drawLine1(page, r.delivery.name, innerR, b, { size: 10.5, font: f.bold, maxWidth: sideW, align: "right" });
      for (const l of [r.delivery.place, r.delivery.when]) {
        if (!l) continue;
        b += 12.5;
        drawLine1(page, l, innerR, b, { size: 9.4, font: f.reg, color: C.text2, maxWidth: sideW, align: "right" });
      }
    }
    const arrowTop = top + h / 2;
    if (r.middleTop) drawLine1(page, r.middleTop, midCx, arrowTop - 7, { size: 9, font: f.reg, color: C.text2, align: "center", maxWidth: midW });
    const ax1 = midCx - midW / 2;
    const ax2 = midCx + midW / 2;
    page.drawLine({ start: { x: ax1, y: PAGE_H - arrowTop }, end: { x: ax2 - 1, y: PAGE_H - arrowTop }, thickness: 1.5, color: accent });
    page.drawSvgPath(`M ${-5} ${-5} L 0 0 L ${-5} 5`, {
      x: ax2,
      y: PAGE_H - arrowTop,
      borderColor: accent,
      borderWidth: 1.6,
      borderLineCap: LineCapStyle.Round,
    });
    if (r.middleBottom) drawLine1(page, r.middleBottom, midCx, arrowTop + 15, { size: 9, font: f.reg, color: C.text2, align: "center", maxWidth: midW + 20 });
    top += h + 15;
  }

  // ---- Charges table ---------------------------------------------------------
  const tx = { desc: ML + 10.5, qtyR: ML + CW - 10.5 - 90 - 82.5, rateR: ML + CW - 10.5 - 90, amtR: ML + CW - 10.5 };
  const descW = tx.qtyR - 67.5 + 6 - tx.desc;
  const tableHeader = () => {
    box(page, ML, top, CW, 24, { radius: [4.5, 4.5, 0, 0], fill: C.headFill });
    hline(page, ML, ML + CW, top + 24, C.border);
    const b = top + 15;
    sectionLabel(page, f, "Description", tx.desc, b, "left", C.text2);
    sectionLabel(page, f, "Qty", tx.qtyR, b, "right", C.text2);
    sectionLabel(page, f, "Rate", tx.rateR, b, "right", C.text2);
    sectionLabel(page, f, "Amount", tx.amtR, b, "right", C.text2);
    top += 24;
  };
  const continuePage = () => {
    page = newPage();
    pages.push(page);
    top = drawContinuationHeader(page, f, accent, doc.org.name, `INVOICE ${doc.number} (continued)`);
  };

  tableHeader();
  const items = doc.lines.length ? doc.lines : [{ description: "No charges listed", qty: "", rate: "", amount: "" }];
  items.forEach((li, i) => {
    const descLines = wrapText(li.description, f.reg, 9.75, descW);
    const rowH = 8.25 * 2 + 12 * descLines.length;
    if (top + rowH > CONTENT_BOTTOM) {
      continuePage();
      tableHeader();
    }
    const b = top + 8.25 + 9;
    descLines.forEach((dl, j) => drawLine1(page, dl, tx.desc, b + j * 12, { size: 9.75, font: j === 0 ? f.bold : f.reg, color: doc.lines.length ? C.ink : C.muted }));
    drawLine1(page, li.qty, tx.qtyR, b, { size: 9.4, font: f.reg, align: "right" });
    drawLine1(page, li.rate, tx.rateR, b, { size: 9.4, font: f.reg, align: "right" });
    drawLine1(page, li.amount, tx.amtR, b, { size: 9.4, font: f.reg, align: "right" });
    top += rowH;
    hline(page, ML, ML + CW, top, i === items.length - 1 ? C.border : C.rule);
  });

  // ---- Notes / documents (left) + totals (right) ---------------------------
  const totalsW = 225;
  const leftW = CW - totalsW - 24;
  const noteBlocks: { label: string; lines: string[] }[] = [];
  if (doc.documentsIncluded.length) noteBlocks.push({ label: "Documents included", lines: wrapText(doc.documentsIncluded.join(" · "), f.reg, 9, leftW) });
  if (doc.notes) noteBlocks.push({ label: "Notes", lines: wrapText(doc.notes, f.reg, 9, leftW).slice(0, 6) });
  const leftH = noteBlocks.reduce((h, nb) => h + 13 + nb.lines.length * 11.5 + 8, 0);
  const totalsH = doc.totals.length * 16.5 + 6 + 36;
  const noaLines = doc.noa ? wrapText(doc.noa.body, f.reg, 9, CW - 24 - 30) : [];
  const noaH = doc.noa ? 13.5 + 18 + 11.5 * noaLines.length + 10 : 0;
  if (top + 12 + Math.max(leftH, totalsH) + noaH > CONTENT_BOTTOM) continuePage();
  top += 12;

  let lb = top + 9;
  for (const nb of noteBlocks) {
    sectionLabel(page, f, nb.label, ML, lb);
    lb += 13;
    for (const l of nb.lines) {
      drawLine1(page, l, ML, lb, { size: 9, font: f.reg, color: C.text2 });
      lb += 11.5;
    }
    lb += 8;
  }

  const tL = PAGE_W - MR - totalsW;
  let tb = top + 10;
  for (const [l, v] of doc.totals) {
    drawLine1(page, l, tL + 10.5, tb, { size: 9.75, font: f.reg, color: C.muted });
    drawLine1(page, v, PAGE_W - MR - 10.5, tb, { size: 9.75, font: f.reg, align: "right" });
    tb += 16.5;
  }
  const dueTop = tb - 16.5 + 12;
  box(page, tL, dueTop, totalsW, 36, { radius: 6, fill: accent });
  sectionLabel(page, f, "Total due", tL + 10.5, dueTop + 21.5, "left", C.white);
  drawLine1(page, doc.totalDue, PAGE_W - MR - 10.5, dueTop + 24, { size: 16.5, font: f.bold, color: C.white, align: "right" });
  top = Math.max(lb - 8, dueTop + 36);

  // ---- Notice of assignment --------------------------------------------------
  if (doc.noa) {
    top += 13.5;
    box(page, ML, top, CW, noaH - 13.5, { radius: 6, stroke: C.ink, strokeWidth: 1.5 });
    // warning triangle
    page.drawSvgPath("M12 3 L21 19 H3 Z M12 10 V14 M12 17 V17.2", {
      x: ML + 10,
      y: PAGE_H - (top + 9),
      scale: 0.7,
      borderColor: C.ink,
      borderWidth: 2,
      borderLineCap: LineCapStyle.Round,
    });
    const nx = ML + 12 + 24;
    let nb = top + 9 + 9;
    drawLine1(page, "NOTICE OF ASSIGNMENT", nx, nb, { size: 9, font: f.bold, spacing: 0.6 });
    nb += 13;
    for (const l of noaLines) {
      drawLine1(page, l, nx, nb, { size: 9, font: f.reg });
      nb += 11.5;
    }
  }

  drawFooters(pages, f, [doc.footerReminder, doc.org.footer ?? "Late payments may incur a fee per the rate confirmation."], "Thank you for your business.");
  return pages;
}

// Billing packet cover: same header, then a summary of the shipment, a
// checklist of what's attached, and -- never silently -- anything that could
// not be included.
export function drawPacketCover(
  page: PDFPage,
  doc: InvoiceDoc,
  f: BrandFonts,
  included: string[],
  skipped: { label: string; filename: string; reason: string }[]
) {
  const accent = hex(doc.accent);
  const grid = doc.grid.filter(([l]) => l !== "Terms");
  let top = drawHeader(page, f, accent, doc.org, "BILLING PACKET", grid);

  // Bill to + amount
  const colW = (CW - 30) / 3;
  sectionLabel(page, f, "Bill to", ML, top + 7);
  let b = top + 22;
  drawLine1(page, doc.billTo.name, ML, b, { size: 10.5, font: f.bold, maxWidth: colW * 2 });
  for (const l of doc.billTo.lines) {
    b += 12.5;
    drawLine1(page, l, ML, b, { size: 9.4, font: f.reg, color: C.text2, maxWidth: colW * 2 });
  }
  const boxW = 225;
  box(page, PAGE_W - MR - boxW, top, boxW, 48, { radius: 6, fill: accent });
  sectionLabel(page, f, "Total due", PAGE_W - MR - boxW + 10.5, top + 18, "left", C.white);
  drawLine1(page, doc.totalDue, PAGE_W - MR - 10.5, top + 38, { size: 18, font: f.bold, color: C.white, align: "right" });
  top = Math.max(b, top + 48) + 20;

  // Route
  if (doc.route) {
    const rows: [string, string][] = [];
    const stop = (s: NonNullable<InvoiceDoc["route"]>["pickup"]) => (s ? [s.name, s.place, s.when].filter(Boolean).join(" · ") : null);
    const p = stop(doc.route.pickup);
    const d = stop(doc.route.delivery);
    if (p) rows.push(["Pickup", p]);
    if (d) rows.push(["Delivery", d]);
    const eq = joinNonEmpty([doc.route.middleTop, doc.route.middleBottom], " · ");
    if (eq) rows.push(["Shipment", eq]);
    for (const [l, v] of doc.references) rows.push([l, v]);
    sectionLabel(page, f, "Shipment", ML, top + 7);
    top += 15;
    for (const [l, v] of rows) {
      hline(page, ML, ML + CW, top, C.rule);
      drawLine1(page, l, ML, top + 14, { size: 9.4, font: f.reg, color: C.muted });
      drawLine1(page, v, ML + 90, top + 14, { size: 9.4, font: f.reg, maxWidth: CW - 90 });
      top += 20;
    }
    hline(page, ML, ML + CW, top, C.rule);
    top += 22;
  }

  // Documents checklist
  sectionLabel(page, f, "Documents included", ML, top + 7);
  top += 15;
  included.forEach((label, i) => {
    box(page, ML, top + 2, 14, 14, { radius: 3, fill: accent });
    page.drawSvgPath("M 3.5 7.5 L 6 10 L 10.5 4.5", { x: ML, y: PAGE_H - (top + 2), borderColor: C.white, borderWidth: 1.6, borderLineCap: LineCapStyle.Round });
    drawLine1(page, label, ML + 22, top + 12.5, { size: 10, font: f.reg, maxWidth: CW - 60 });
    drawLine1(page, String(i + 1), PAGE_W - MR, top + 12.5, { size: 9, font: f.reg, color: C.muted, align: "right" });
    top += 22;
  });

  if (skipped.length) {
    top += 8;
    const warn = hex("#b45309");
    const lines = skipped.flatMap((s) => wrapText(`${s.label} (${s.filename}): ${s.reason}`, f.reg, 9, CW - 30));
    const h = 22 + lines.length * 11.5 + 8;
    box(page, ML, top, CW, h, { radius: 6, stroke: warn, strokeWidth: 1.2, fill: hex("#fff7ed") });
    drawLine1(page, "COULD NOT INCLUDE", ML + 12, top + 15, { size: 8.6, font: f.bold, color: warn, spacing: 0.6 });
    let wb = top + 28;
    for (const l of lines) {
      drawLine1(page, l, ML + 12, wb, { size: 9, font: f.reg, color: warn });
      wb += 11.5;
    }
  }

  drawFooters([page], f, [`Billing packet for invoice # ${doc.number}.`, doc.footerReminder], "Thank you for your business.", false);
}

export async function renderInvoicePdf(src: InvoiceSource): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  const fonts = await embedBrandFonts(pdf);
  drawInvoice(buildInvoiceDoc(src), fonts, () => pdf.addPage([PAGE_W, PAGE_H]));
  pdf.setTitle(pdfSafe(`Invoice ${src.invoice.invoice_number}`));
  return pdf.save();
}

// =============================================================================
// STATEMENT
// =============================================================================

export type StatementSource = {
  organization: { name: string; address: string | null; phone: string | null; email: string | null; authority?: string | null; footer?: string | null; remitLines?: string[] | null };
  party: { company_name: string; email: string | null; address: string | null; paymentTermsDays: number | null };
  statementType: "open_balance" | "period" | "aging";
  statementDate: string;
  periodStart: string | null;
  periodEnd: string | null;
  asOfDate: string;
  openingBalance: number;
  closingBalance: number;
  periodCharges: number;
  periodPayments: number;
  transactions: { txn_date: string; txn_type: string; reference: string; load_number: string | null; charge_amount: number; payment_amount: number; is_voided: boolean; running_balance: number }[];
  openInvoices: { invoice_number: string; load_number: string | null; issue_date: string; due_date: string | null; total_amount: number; amount_paid: number; balance_due: number; days_past_due: number }[];
  aging: { current: number; bucket_1_30: number; bucket_31_60: number; bucket_61_90: number; bucket_90_plus: number; total_outstanding: number };
  bankInstructions: { bankName: string; accountNickname: string | null; accountType: string; routingLast4: string | null; accountLast4: string | null } | null;
  accent?: string;
};

export function statementCards(d: StatementSource): { label: string; value: string; sub: string | null; emphasis?: boolean }[] {
  const n = (v: unknown) => Number(v ?? 0) || 0;
  const pastDue = n(d.aging.total_outstanding) - n(d.aging.current);
  const balance = { label: "Balance due", value: formatMoney(d.closingBalance), sub: pastDue > 0 ? `${formatMoney(pastDue)} past due` : "Nothing past due", emphasis: true };
  if (d.statementType === "period") {
    return [
      { label: "Charges", value: formatMoney(d.periodCharges), sub: `Opening ${formatMoney(d.openingBalance)}` },
      { label: "Payments", value: formatMoney(d.periodPayments), sub: "This period" },
      balance,
    ];
  }
  const invoiced = d.openInvoices.reduce((s, r) => s + n(r.total_amount), 0);
  const paid = d.openInvoices.reduce((s, r) => s + n(r.amount_paid), 0);
  const paidCount = d.openInvoices.filter((r) => n(r.amount_paid) > 0).length;
  const count = d.openInvoices.length;
  return [
    { label: "Total invoiced", value: formatMoney(invoiced), sub: `${count} open invoice${count === 1 ? "" : "s"}` },
    { label: "Payments", value: formatMoney(paid), sub: paidCount ? `Applied to ${paidCount} invoice${paidCount === 1 ? "" : "s"}` : "None applied yet" },
    balance,
  ];
}

export async function renderStatementDocument(d: StatementSource, statementNumber: string): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  const f = await embedBrandFonts(pdf);
  const accent = hex(d.accent ?? DEFAULT_ACCENT);
  const org: DocOrg = { name: d.organization.name, address: d.organization.address, contact: joinNonEmpty([d.organization.phone, d.organization.email], " · "), authority: d.organization.authority ?? null, footer: d.organization.footer ?? null };
  const pages: PDFPage[] = [];
  let page = pdf.addPage([PAGE_W, PAGE_H]);
  pages.push(page);

  const grid: [string, string, boolean?][] = [
    ["Statement #", statementNumber, true],
    ["Statement date", formatDate(d.statementDate)],
    d.statementType === "period" ? ["Period", `${formatDate(d.periodStart)} – ${formatDate(d.periodEnd)}`] : ["As of", formatDate(d.asOfDate)],
  ];
  if (d.party.paymentTermsDays != null) grid.push(["Terms", d.party.paymentTermsDays === 0 ? "Due on receipt" : `Net ${d.party.paymentTermsDays}`]);
  let top = drawHeader(page, f, accent, org, "STATEMENT", grid);

  // ---- Party + summary cards -------------------------------------------------
  const partyW = 165;
  sectionLabel(page, f, "Statement for", ML, top + 7);
  let pb = top + 7 + 15;
  for (const nl of wrapText(d.party.company_name, f.bold, 10.5, partyW).slice(0, 2)) {
    drawLine1(page, nl, ML, pb, { size: 10.5, font: f.bold });
    pb += 13;
  }
  for (const l of [...splitLines(d.party.address, 2), ...(d.party.email ? [d.party.email] : [])]) {
    drawLine1(page, l, ML, pb, { size: 9.4, font: f.reg, color: C.text2, maxWidth: partyW });
    pb += 12.5;
  }
  const cards = statementCards(d);
  const cardsX = ML + partyW + 15;
  const cardW = (PAGE_W - MR - cardsX - 2 * 9) / 3;
  const cardH = 60;
  cards.forEach((c, i) => {
    const x = cardsX + i * (cardW + 9);
    box(page, x, top, cardW, cardH, c.emphasis ? { radius: 6, fill: accent } : { radius: 6, stroke: C.border });
    const fg = c.emphasis ? C.white : C.ink;
    sectionLabel(page, f, c.label, x + 10.5, top + 17, "left", c.emphasis ? C.white : C.muted, cardW - 21);
    drawLine1(page, c.value, x + 10.5, top + 36, { size: 15, font: f.bold, color: fg, maxWidth: cardW - 21 });
    if (c.sub) drawLine1(page, c.sub, x + 10.5, top + 50, { size: 8.25, font: f.reg, color: c.emphasis ? C.white : C.muted, maxWidth: cardW - 21 });
  });
  top = Math.max(pb - 8, top + cardH) + 18;

  // ---- Aging bar ---------------------------------------------------------------
  const buckets: [string, number, RGB][] = [
    ["Current", d.aging.current, accent],
    ["1–30 days", d.aging.bucket_1_30, C.aging[0]],
    ["31–60 days", d.aging.bucket_31_60, C.aging[1]],
    ["61–90 days", d.aging.bucket_61_90, C.aging[2]],
    ["90+ days", d.aging.bucket_90_plus, C.aging[3]],
  ];
  sectionLabel(page, f, "Aging summary", ML, top + 7);
  drawLine1(page, `As of ${formatDate(d.asOfDate)}`, PAGE_W - MR, top + 7, { size: 8.6, font: f.reg, color: C.muted, align: "right" });
  top += 15;
  const barH = 9;
  const total = buckets.reduce((s, [, v]) => s + Math.max(0, Number(v) || 0), 0);
  box(page, ML, top, CW, barH, { radius: 4.5, fill: C.empty });
  if (total > 0) {
    const segs = buckets.filter(([, v]) => Number(v) > 0);
    let x = ML;
    segs.forEach(([, v, color], i) => {
      const w = i === segs.length - 1 ? ML + CW - x : (CW * Number(v)) / total;
      const first = i === 0;
      const last = i === segs.length - 1;
      box(page, x, top, w, barH, { radius: [first ? 4.5 : 0, last ? 4.5 : 0, last ? 4.5 : 0, first ? 4.5 : 0], fill: color });
      x += w;
    });
  }
  top += barH + 12;
  const bW = CW / 5;
  buckets.forEach(([label, v, color], i) => {
    const x = ML + i * bW;
    box(page, x, top, 6.75, 6.75, { radius: 1.5, fill: color });
    drawLine1(page, label, x + 10.5, top + 6.5, { size: 8.6, font: f.reg, color: C.muted });
    drawLine1(page, formatMoney(v), x, top + 21, { size: 10.5, font: f.bold, color: Number(v) > 0 && i >= 3 ? C.overdue : C.ink });
  });
  top += 21 + 18;

  // ---- Table ---------------------------------------------------------------------
  type Col = { label: string; x: number; align: "left" | "right" };
  const period = d.statementType === "period";
  const R = PAGE_W - MR - 9;
  const cols: Col[] = period
    ? [
        { label: "Date", x: ML + 9, align: "left" },
        { label: "Type", x: ML + 82, align: "left" },
        { label: "Reference", x: ML + 172, align: "left" },
        { label: "Load", x: ML + 262, align: "left" },
        { label: "Charges", x: R - 150, align: "right" },
        { label: "Payments", x: R - 75, align: "right" },
        { label: "Balance", x: R, align: "right" },
      ]
    : [
        { label: "Invoice", x: ML + 9, align: "left" },
        { label: "Load", x: ML + 78, align: "left" },
        { label: "Invoiced", x: ML + 152, align: "left" },
        { label: "Due", x: ML + 222, align: "left" },
        { label: "Days", x: R - 222, align: "right" },
        { label: "Amount", x: R - 148, align: "right" },
        { label: "Paid", x: R - 74, align: "right" },
        { label: "Balance", x: R, align: "right" },
      ];
  const widths = cols.map((c, i) => (c.align === "left" ? (cols[i + 1] ? cols[i + 1].x - c.x - 6 : 80) : 70));
  const header = () => {
    box(page, ML, top, CW, 22, { radius: [4.5, 4.5, 0, 0], fill: C.headFill });
    hline(page, ML, ML + CW, top + 22, C.border);
    cols.forEach((c) => sectionLabel(page, f, c.label, c.x, top + 14, c.align, C.text2));
    top += 22;
  };
  const SLIP_H = 120;
  const newPage = () => {
    page = pdf.addPage([PAGE_W, PAGE_H]);
    pages.push(page);
    top = drawContinuationHeader(page, f, accent, org.name, `STATEMENT ${statementNumber} (continued)`);
  };
  type Cell = { text: string; color?: RGB; bold?: boolean };
  const rows: Cell[][] = period
    ? d.transactions.map((t) => {
        const muted = t.is_voided ? C.muted : undefined;
        return [
          { text: formatDate(t.txn_date), color: muted },
          { text: t.txn_type === "invoice" ? "Invoice" : t.is_voided ? "Payment (voided)" : "Payment", color: muted },
          { text: t.reference, color: muted, bold: true },
          { text: t.load_number ?? "—", color: muted },
          { text: Number(t.charge_amount) > 0 ? formatMoney(t.charge_amount, { symbol: false }) : "—", color: muted },
          { text: Number(t.payment_amount) > 0 ? formatMoney(t.payment_amount, { symbol: false }) : t.is_voided ? "VOIDED" : "—", color: t.is_voided ? C.overdue : undefined },
          { text: formatMoney(t.running_balance, { symbol: false }), bold: true, color: muted },
        ];
      })
    : d.openInvoices.map((r) => {
        const days = Number(r.days_past_due) || 0;
        return [
          { text: r.invoice_number, bold: true },
          { text: r.load_number ?? "—" },
          { text: formatDate(r.issue_date) },
          { text: formatDate(r.due_date) },
          { text: days > 0 ? String(days) : "—", color: days > 60 ? C.overdue : days > 0 ? C.ink : C.muted, bold: days > 0 },
          { text: formatMoney(r.total_amount, { symbol: false }) },
          { text: Number(r.amount_paid) > 0 ? formatMoney(r.amount_paid, { symbol: false }) : "—", color: Number(r.amount_paid) > 0 ? undefined : C.muted },
          { text: formatMoney(r.balance_due, { symbol: false }), bold: true },
        ];
      });

  header();
  const ROW_H = 20;
  if (rows.length === 0) {
    drawLine1(page, period ? "No activity during this period." : "No open invoices as of this date.", ML + 9, top + 13.5, { size: 9.4, font: f.reg, color: C.muted });
    top += ROW_H;
    hline(page, ML, ML + CW, top, C.rule);
  }
  rows.forEach((cells) => {
    if (top + ROW_H > CONTENT_BOTTOM) {
      newPage();
      header();
    }
    cells.forEach((cell, i) => {
      const c = cols[i];
      drawLine1(page, cell.text, c.x, top + 13.5, { size: 9, font: cell.bold ? f.bold : f.reg, color: cell.color ?? C.ink, align: c.align, maxWidth: widths[i] });
    });
    top += ROW_H;
    hline(page, ML, ML + CW, top, C.rule);
  });
  // closing row
  if (top + 26 > CONTENT_BOTTOM) newPage();
  hline(page, ML, ML + CW, top, C.border);
  sectionLabel(page, f, period ? "Closing balance" : "Balance due", R - 110, top + 16, "right");
  drawLine1(page, formatMoney(d.closingBalance), R, top + 16.5, { size: 11.25, font: f.bold, align: "right" });
  top += 26;

  // ---- Remittance slip (bottom of the last page) ----------------------------------
  if (top + 18 + SLIP_H > CONTENT_BOTTOM) {
    page = pdf.addPage([PAGE_W, PAGE_H]);
    pages.push(page);
    drawContinuationHeader(page, f, accent, org.name, `STATEMENT ${statementNumber}`);
  }
  const slipTop = CONTENT_BOTTOM - SLIP_H;
  const cut = "DETACH AND RETURN WITH YOUR PAYMENT";
  const cutW = textWidth(cut, f.bold, 7.5, 0.6);
  hline(page, ML, PAGE_W / 2 - cutW / 2 - 9, slipTop, C.border, 0.75, [3, 3]);
  hline(page, PAGE_W / 2 + cutW / 2 + 9, PAGE_W - MR, slipTop, C.border, 0.75, [3, 3]);
  drawLine1(page, cut, PAGE_W / 2, slipTop + 2.5, { size: 7.5, font: f.bold, color: C.muted, align: "center", spacing: 0.6 });

  const sTop = slipTop + 16;
  const sColW = (CW - 30) / 3;
  const sx = [ML, ML + sColW + 15, ML + 2 * (sColW + 15)];
  sectionLabel(page, f, "Remit to", sx[0], sTop + 7);
  let rb = sTop + 22;
  drawLine1(page, org.name, sx[0], rb, { size: 10.5, font: f.bold, maxWidth: sColW });
  const remitLines = d.organization.remitLines?.length ? d.organization.remitLines : splitLines(d.organization.address?.replace(/ · /g, "\n"), 3);
  for (const l of remitLines.slice(0, 3)) {
    rb += 12.5;
    drawLine1(page, l, sx[0], rb, { size: 9.4, font: f.reg, color: C.text2, maxWidth: sColW });
  }
  if (d.bankInstructions) {
    const b = d.bankInstructions;
    rb += 12.5;
    drawLine1(page, `ACH: ${b.bankName}${b.accountLast4 ? ` · acct ...${b.accountLast4}` : ""}`, sx[0], rb, { size: 8.6, font: f.reg, color: C.muted, maxWidth: sColW });
  }

  const kv: [string, string][] = [
    ["Account", d.party.company_name],
    ["Statement #", statementNumber],
    ["Balance due", formatMoney(d.closingBalance)],
  ];
  let kb = sTop + 7;
  for (const [k, v] of kv) {
    drawLine1(page, k, sx[1], kb, { size: 9.4, font: f.reg, color: C.muted });
    drawLine1(page, v, sx[1] + 66, kb, { size: 9.4, font: k === "Balance due" ? f.bold : f.reg, maxWidth: sColW - 66 });
    kb += 14;
  }

  sectionLabel(page, f, "Amount enclosed", sx[2], sTop + 7);
  box(page, sx[2], sTop + 14, sColW, 30, { radius: 4.5, stroke: C.border });
  drawLine1(page, "$", sx[2] + 9, sTop + 33.5, { size: 12, font: f.reg, color: C.muted });
  drawLine1(page, "List invoice numbers paid on your remittance.", sx[2], sTop + 56, { size: 8.25, font: f.reg, color: C.muted, maxWidth: sColW });

  drawFooters(pages, f, [org.footer ?? "Questions about this statement? Contact us at the phone or email above."], "Thank you for your business.");
  pdf.setTitle(pdfSafe(`Statement ${statementNumber}`));
  return pdf.save();
}
