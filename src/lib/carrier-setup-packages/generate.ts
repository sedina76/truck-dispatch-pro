import "server-only";
import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "pdf-lib";
import { createHash } from "node:crypto";
import {
  DOCUMENT_LABELS,
  MAX_GENERATED_BYTES,
  MAX_PACKAGE_PAGES,
  type CarrierSnapshot,
  type EquipmentSnapshot,
  type OrganizationSnapshot,
  type SetupPackageItemRow,
} from "./types";

const LETTER_WIDTH = 612;
const LETTER_HEIGHT = 792;
const MARGIN = 52;
const NAVY = rgb(0.08, 0.16, 0.25);
const SLATE = rgb(0.35, 0.4, 0.47);
const LIGHT = rgb(0.9, 0.92, 0.94);

export type SourceFile = { item: SetupPackageItemRow; bytes: Uint8Array };
export type GeneratedSetupPackage = {
  bytes: Uint8Array;
  pageCount: number;
  itemResults: { item_id: string; source_content_hash: string; start_page: number; end_page: number }[];
};

type PackagePdfInput = {
  version: number;
  preparedAt: Date;
  preparedForName: string | null;
  recipientName: string | null;
  recipientEmail: string | null;
  carrier: CarrierSnapshot;
  organization: OrganizationSnapshot;
  equipment: EquipmentSnapshot | null;
  sources: SourceFile[];
};

type PreparedSource = SourceFile & { pageCount: number; sourcePdf?: PDFDocument };

export async function renderCarrierSetupPackage(input: PackagePdfInput): Promise<GeneratedSetupPackage> {
  if (input.sources.length === 0) throw new Error("Select at least one source document.");
  const prepared: PreparedSource[] = [];
  for (const source of [...input.sources].sort((a, b) => a.item.display_order - b.item.display_order)) {
    const mime = source.item.source_mime_type;
    if (mime === "application/pdf") {
      let sourcePdf: PDFDocument;
      try {
        sourcePdf = await PDFDocument.load(source.bytes, { ignoreEncryption: true });
      } catch {
        throw new Error(`${source.item.source_filename} is not a readable PDF.`);
      }
      let pageCount: number;
      try {
        pageCount = sourcePdf.getPageCount();
      } catch {
        throw new Error(`${source.item.source_filename} has an invalid PDF page structure.`);
      }
      if (pageCount < 1) throw new Error(`${source.item.source_filename} has no pages.`);
      prepared.push({ ...source, pageCount, sourcePdf });
    } else if (mime === "image/jpeg" || mime === "image/png") {
      prepared.push({ ...source, pageCount: 1 });
    } else if (mime === "image/heic") {
      throw new Error(`Convert ${source.item.source_filename} from HEIC to PDF, JPG, or PNG before including it.`);
    } else {
      throw new Error(`${source.item.source_filename} has an unsupported file type.`);
    }
  }

  const pageCount = 3 + prepared.reduce((sum, source) => sum + source.pageCount, 0);
  if (pageCount > MAX_PACKAGE_PAGES) throw new Error(`This package would contain ${pageCount} pages; the maximum is ${MAX_PACKAGE_PAGES}.`);

  const ranges = new Map<string, { start: number; end: number }>();
  let cursor = 4;
  for (const source of prepared) {
    ranges.set(source.item.id, { start: cursor, end: cursor + source.pageCount - 1 });
    cursor += source.pageCount;
  }

  const pdf = await PDFDocument.create();
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  drawCover(pdf.addPage([LETTER_WIDTH, LETTER_HEIGHT]), input, regular, bold);
  drawContents(pdf.addPage([LETTER_WIDTH, LETTER_HEIGHT]), prepared, ranges, regular, bold);
  drawCarrierProfile(pdf.addPage([LETTER_WIDTH, LETTER_HEIGHT]), input, regular, bold);

  for (const source of prepared) {
    if (source.sourcePdf) {
      try {
        const pages = await pdf.copyPages(source.sourcePdf, source.sourcePdf.getPageIndices());
        for (const page of pages) pdf.addPage(page);
      } catch {
        throw new Error(`${source.item.source_filename} could not be merged because its PDF structure is unsupported.`);
      }
      continue;
    }
    const page = pdf.addPage([LETTER_WIDTH, LETTER_HEIGHT]);
    try {
      const image = source.item.source_mime_type === "image/png" ? await pdf.embedPng(source.bytes) : await pdf.embedJpg(source.bytes);
      const maxWidth = LETTER_WIDTH - MARGIN * 2;
      const maxHeight = LETTER_HEIGHT - MARGIN * 2;
      const scale = Math.min(maxWidth / image.width, maxHeight / image.height, 1);
      const width = image.width * scale;
      const height = image.height * scale;
      page.drawImage(image, { x: (LETTER_WIDTH - width) / 2, y: (LETTER_HEIGHT - height) / 2, width, height });
    } catch {
      throw new Error(`${source.item.source_filename} is not a readable ${source.item.source_mime_type === "image/png" ? "PNG" : "JPEG"} image.`);
    }
  }

  const bytes = await pdf.save({ useObjectStreams: true });
  if (bytes.length > MAX_GENERATED_BYTES) throw new Error("The generated PDF exceeds the 50 MB package limit.");
  return {
    bytes,
    pageCount,
    itemResults: prepared.map((source) => ({
      item_id: source.item.id,
      source_content_hash: createHash("sha256").update(source.bytes).digest("hex"),
      start_page: ranges.get(source.item.id)!.start,
      end_page: ranges.get(source.item.id)!.end,
    })),
  };
}

function drawCover(page: PDFPage, input: PackagePdfInput, regular: PDFFont, bold: PDFFont) {
  page.drawRectangle({ x: 0, y: LETTER_HEIGHT - 10, width: LETTER_WIDTH, height: 10, color: NAVY });
  page.drawText(input.organization.name || "Dispatch Company", { x: MARGIN, y: 724, size: 11, font: bold, color: NAVY });
  page.drawText("CARRIER SETUP PACKAGE", { x: MARGIN, y: 630, size: 25, font: bold, color: NAVY });
  page.drawRectangle({ x: MARGIN, y: 611, width: 70, height: 3, color: NAVY });
  let y = 565;
  y = wrapped(page, input.carrier.legal_name || "Carrier", MARGIN, y, bold, 21, LETTER_WIDTH - MARGIN * 2, 25, NAVY);
  if (input.carrier.dba_name) y = wrapped(page, `DBA ${input.carrier.dba_name}`, MARGIN, y - 2, regular, 11, LETTER_WIDTH - MARGIN * 2, 15, SLATE);
  const identifiers = [input.carrier.mc_number ? `MC # ${input.carrier.mc_number}` : null, input.carrier.dot_number ? `USDOT # ${input.carrier.dot_number}` : null].filter(Boolean).join("    ");
  if (identifiers) page.drawText(identifiers, { x: MARGIN, y: y - 8, size: 11, font: bold, color: NAVY });

  const preparedFor = input.preparedForName || input.recipientName || input.recipientEmail;
  sectionLabel(page, "PREPARED FOR", 390, bold);
  let py = 366;
  for (const line of [preparedFor, input.recipientName && input.recipientName !== preparedFor ? input.recipientName : null, input.recipientEmail]) {
    if (line) { page.drawText(line, { x: MARGIN, y: py, size: 10.5, font: py === 366 ? bold : regular, color: NAVY }); py -= 17; }
  }
  if (!preparedFor) page.drawText("General broker setup package", { x: MARGIN, y: py, size: 10.5, font: regular, color: SLATE });

  sectionLabel(page, "CARRIER CONTACT", 275, bold);
  let cy = 251;
  for (const line of [input.carrier.contact_name, input.carrier.phone, input.carrier.email]) {
    if (line) { page.drawText(line, { x: MARGIN, y: cy, size: 10.5, font: regular, color: NAVY }); cy -= 17; }
  }
  page.drawLine({ start: { x: MARGIN, y: 130 }, end: { x: LETTER_WIDTH - MARGIN, y: 130 }, thickness: 1, color: LIGHT });
  smallPair(page, "Prepared", formatDate(input.preparedAt), MARGIN, 102, regular, bold);
  smallPair(page, "Prepared By", input.organization.name, 250, 102, regular, bold);
  smallPair(page, "Package", `v${input.version}`, 470, 102, regular, bold);
}

function drawContents(page: PDFPage, sources: PreparedSource[], ranges: Map<string, { start: number; end: number }>, regular: PDFFont, bold: PDFFont) {
  header(page, "PACKAGE CONTENTS", "Carrier Setup Package", regular, bold);
  let y = 685;
  const rows = [{ label: "Carrier Profile", pages: "3" }, ...sources.map((source) => {
    const range = ranges.get(source.item.id)!;
    return { label: DOCUMENT_LABELS[source.item.document_type] ?? source.item.document_type.replaceAll("_", " "), pages: range.start === range.end ? String(range.start) : `${range.start}-${range.end}` };
  })];
  rows.forEach((row, index) => {
    page.drawText(String(index + 1).padStart(2, "0"), { x: MARGIN, y, size: 9, font: bold, color: SLATE });
    page.drawText(row.label, { x: MARGIN + 34, y, size: 11, font: index === 0 ? bold : regular, color: NAVY });
    const width = regular.widthOfTextAtSize(row.pages, 10);
    page.drawText(row.pages, { x: LETTER_WIDTH - MARGIN - width, y, size: 10, font: regular, color: SLATE });
    page.drawLine({ start: { x: MARGIN + 34, y: y - 10 }, end: { x: LETTER_WIDTH - MARGIN, y: y - 10 }, thickness: 0.5, color: LIGHT });
    y -= 43;
  });
  footer(page, 2, regular);
}

function drawCarrierProfile(page: PDFPage, input: PackagePdfInput, regular: PDFFont, bold: PDFFont) {
  header(page, "CARRIER PROFILE", input.carrier.legal_name, regular, bold);
  // Keep the first section comfortably below header()'s rule at y=696.
  // profileSection() draws its 8.5pt label at this baseline, so 674 leaves
  // deliberate whitespace instead of letting the COMPANY glyphs touch it.
  let y = 674;
  y = profileSection(page, "COMPANY", [
    ["Legal Name", input.carrier.legal_name], ["DBA", input.carrier.dba_name], ["MC Number", input.carrier.mc_number], ["USDOT Number", input.carrier.dot_number], ["Address", input.carrier.address],
  ], y, regular, bold);
  y = profileSection(page, "PRIMARY CONTACT", [["Contact", input.carrier.contact_name], ["Phone", input.carrier.phone], ["Email", input.carrier.email]], y, regular, bold);
  const equipment = input.equipment;
  if (equipment) y = profileSection(page, "EQUIPMENT", [
    ["Primary Type", labelValue(equipment.equipment_type)], ["Trucks", numberValue(equipment.truck_count)], ["Trailers", numberValue(equipment.trailer_count)],
    ["Trailer Types", equipment.trailer_types?.join(", ")], ["Preferred Freight", equipment.preferred_freight], ["Operating Regions", equipment.operating_regions?.join(", ")],
  ], y, regular, bold);
  y = profileSection(page, "BROKER SETUP", [["Factoring Company", input.carrier.factoring_company_name]], y, regular, bold);
  const compliance = input.carrier.compliance ?? [];
  if (compliance.length) profileSection(page, "DOCUMENT STATUS", compliance.map((entry) => [DOCUMENT_LABELS[entry.document_type] ?? entry.document_type.replaceAll("_", " "), `${entry.expiry_date ? `Expires ${formatDate(new Date(`${entry.expiry_date}T00:00:00`))}` : "No expiration"} - Verified`]), y, regular, bold);
  footer(page, 3, regular);
}

function header(page: PDFPage, title: string, subtitle: string, regular: PDFFont, bold: PDFFont) {
  page.drawText(title, { x: MARGIN, y: 730, size: 19, font: bold, color: NAVY });
  page.drawText(subtitle, { x: MARGIN, y: 708, size: 9.5, font: regular, color: SLATE });
  page.drawLine({ start: { x: MARGIN, y: 696 }, end: { x: LETTER_WIDTH - MARGIN, y: 696 }, thickness: 1.2, color: NAVY });
}

function profileSection(page: PDFPage, title: string, rows: [string, string | undefined][], y: number, regular: PDFFont, bold: PDFFont) {
  const visible = rows.filter((row): row is [string, string] => Boolean(row[1]));
  if (!visible.length) return y;
  page.drawText(title, { x: MARGIN, y, size: 8.5, font: bold, color: SLATE }); y -= 22;
  for (const [label, value] of visible) {
    page.drawText(label, { x: MARGIN, y, size: 9.5, font: regular, color: SLATE });
    y = wrapped(page, value, 190, y, regular, 9.5, LETTER_WIDTH - MARGIN - 190, 13, NAVY);
  }
  return y - 12;
}

function wrapped(page: PDFPage, text: string, x: number, y: number, font: PDFFont, size: number, maxWidth: number, lineHeight: number, color = NAVY) {
  let line = "";
  for (const word of text.replace(/[\r\n]+/g, " ").split(/\s+/)) {
    const next = line ? `${line} ${word}` : word;
    if (line && font.widthOfTextAtSize(next, size) > maxWidth) { page.drawText(line, { x, y, size, font, color }); y -= lineHeight; line = word; }
    else line = next;
  }
  if (line) { page.drawText(line, { x, y, size, font, color }); y -= lineHeight; }
  return y;
}

function sectionLabel(page: PDFPage, text: string, y: number, bold: PDFFont) {
  page.drawText(text, { x: MARGIN, y, size: 8.5, font: bold, color: SLATE });
  page.drawLine({ start: { x: MARGIN, y: y - 8 }, end: { x: LETTER_WIDTH - MARGIN, y: y - 8 }, thickness: 0.7, color: LIGHT });
}
function smallPair(page: PDFPage, label: string, value: string, x: number, y: number, regular: PDFFont, bold: PDFFont) { page.drawText(label, { x, y, size: 7.5, font: regular, color: SLATE }); page.drawText(value, { x, y: y - 16, size: 9, font: bold, color: NAVY }); }
function footer(page: PDFPage, pageNumber: number, regular: PDFFont) { page.drawText(`Carrier Setup Package  |  ${pageNumber}`, { x: MARGIN, y: 25, size: 7.5, font: regular, color: SLATE }); }
function formatDate(date: Date) { return new Intl.DateTimeFormat("en-US", { month: "long", day: "numeric", year: "numeric", timeZone: "UTC" }).format(date); }
function labelValue(value?: string) { return value?.replaceAll("_", " ").replace(/\b\w/g, (c) => c.toUpperCase()); }
function numberValue(value?: number) { return value == null ? undefined : String(value); }
