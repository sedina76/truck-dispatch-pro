import "server-only";
import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "pdf-lib";

const PAGE_WIDTH = 612;
const PAGE_HEIGHT = 792;
const LEFT_MARGIN = 52;
const RIGHT_MARGIN = 52;
const HEADER_TITLE_Y = 746;
const HEADER_SUBTITLE_Y = 732;
const HEADER_RULE_Y = 720;
const CONTENT_TOP = 700;
const CONTENT_BOTTOM = 52;
const FOOTER_RULE_Y = 39;
const FOOTER_TEXT_Y = 24;
const CONTENT_WIDTH = PAGE_WIDTH - LEFT_MARGIN - RIGHT_MARGIN;
const CLAUSE_INDENT = 28;
const CLAUSE_WIDTH = CONTENT_WIDTH - CLAUSE_INDENT;
const CLAUSE_TITLE_SIZE = 11;
const CLAUSE_TITLE_LINE_HEIGHT = 14;
const CLAUSE_BODY_SIZE = 9.5;
const CLAUSE_BODY_LINE_HEIGHT = 13;
const CLAUSE_TITLE_BODY_GAP = 5;
const CLAUSE_GAP = 14;
const INITIALS_BLOCK_HEIGHT = 40;
const INITIALS_BOX_HEIGHT = 22;
const CONTINUATION_SIZE = 8.5;
const CONTINUATION_LINE_HEIGHT = 11;
const CONTINUATION_GAP = 9;
const NAVY = rgb(0.07, 0.15, 0.24);
const SLATE = rgb(0.34, 0.39, 0.46);
const LIGHT = rgb(0.88, 0.91, 0.94);

export type ExecutedAgreementClause = {
  title: string;
  body: string;
  displayOrder: number;
  requiresInitials: boolean;
  typedInitials: string | null;
};

export type ExecutedAgreementPdfInput = {
  signingId: string;
  templateId: string;
  templateName: string;
  templateVersion: number;
  signedAt: string;
  signerName: string;
  signerTitle: string | null;
  typedSignature: string;
  consentVersion: string;
  consentAcceptedAt: string;
  contentHash: string;
  evidenceHash: string;
  organizationReferenceName: string | null;
  clauses: ExecutedAgreementClause[];
};

export async function renderExecutedAgreementPdf(input: ExecutedAgreementPdfInput): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  const executionDate = new Date(input.signedAt);
  pdf.setTitle(`${input.templateName} - Executed Agreement`);
  pdf.setSubject(`Executed carrier agreement signing ${input.signingId}`);
  pdf.setProducer("Truck Dispatch Pro");
  pdf.setCreator("Truck Dispatch Pro");
  pdf.setCreationDate(executionDate);
  pdf.setModificationDate(executionDate);
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  let { page, y } = addAgreementPage(pdf, input, regular, bold, false);

  page.drawText("EXECUTED DISPATCH AGREEMENT", { x: LEFT_MARGIN, y, size: 9, font: bold, color: SLATE });
  y -= 34;
  y = drawWrapped(page, input.templateName, LEFT_MARGIN, y, bold, 22, CONTENT_WIDTH, 27, NAVY);
  y -= 9;
  page.drawText(`Agreement version ${input.templateVersion}`, { x: LEFT_MARGIN, y, size: 10, font: regular, color: SLATE });
  y -= 17;
  page.drawText(`Signing ID: ${input.signingId}`, { x: LEFT_MARGIN, y, size: 8.5, font: regular, color: SLATE });
  y -= 17;
  page.drawText(`Executed: ${formatTimestamp(input.signedAt)}`, { x: LEFT_MARGIN, y, size: 9.5, font: bold, color: NAVY });
  y -= 28;
  if (input.organizationReferenceName) {
    page.drawRectangle({ x: LEFT_MARGIN, y: y - 28, width: CONTENT_WIDTH, height: 42, color: rgb(0.96, 0.97, 0.98) });
    page.drawText("DISPATCH ORGANIZATION (CURRENT REFERENCE)", { x: LEFT_MARGIN + 12, y: y - 2, size: 7.5, font: bold, color: SLATE });
    drawWrapped(page, input.organizationReferenceName, LEFT_MARGIN + 12, y - 17, regular, 9.5, CONTENT_WIDTH - 24, 12, NAVY);
    y -= 58;
  }

  for (const [index, clause] of [...input.clauses].sort((a, b) => a.displayOrder - b.displayOrder).entries()) {
    const titleLines = wrap(clause.title, bold, CLAUSE_TITLE_SIZE, CLAUSE_WIDTH);
    const bodyLines = wrapPreservingParagraphs(clause.body, regular, CLAUSE_BODY_SIZE, CLAUSE_WIDTH);
    const usefulFirstBodyLines = Math.min(bodyLines.length, 2);
    const headingMinimum = titleLines.length * CLAUSE_TITLE_LINE_HEIGHT
      + CLAUSE_TITLE_BODY_GAP + usefulFirstBodyLines * CLAUSE_BODY_LINE_HEIGHT;
    if (!hasRoom(y, headingMinimum)) {
      ({ page, y } = addAgreementPage(pdf, input, regular, bold, true));
    }

    const clauseNumber = String(index + 1).padStart(2, "0");
    page.drawText(clauseNumber, { x: LEFT_MARGIN, y, size: 8, font: bold, color: SLATE });
    y = drawLines(page, titleLines, LEFT_MARGIN + CLAUSE_INDENT, y, bold, CLAUSE_TITLE_SIZE, CLAUSE_TITLE_LINE_HEIGHT, NAVY);
    y -= CLAUSE_TITLE_BODY_GAP;
    for (const line of bodyLines) {
      if (!hasRoom(y, CLAUSE_BODY_LINE_HEIGHT)) {
        ({ page, y } = addAgreementPage(pdf, input, regular, bold, true));
        y = drawContinuationLabel(page, clauseNumber, clause.title, "continued", y, bold);
      }
      if (line) page.drawText(line, { x: LEFT_MARGIN + CLAUSE_INDENT, y, size: CLAUSE_BODY_SIZE, font: regular, color: NAVY });
      y -= CLAUSE_BODY_LINE_HEIGHT;
    }
    if (clause.requiresInitials) {
      if (!hasRoom(y, INITIALS_BLOCK_HEIGHT)) {
        ({ page, y } = addAgreementPage(pdf, input, regular, bold, true));
        y = drawContinuationLabel(page, clauseNumber, clause.title, "acknowledgment", y, bold);
      }
      page.drawRectangle({ x: LEFT_MARGIN + CLAUSE_INDENT, y: y - INITIALS_BOX_HEIGHT - 1, width: 190, height: INITIALS_BOX_HEIGHT, borderWidth: 0.8, borderColor: LIGHT });
      page.drawText(`Initials recorded: ${clause.typedInitials ?? ""}`, { x: LEFT_MARGIN + CLAUSE_INDENT + 10, y: y - 16, size: 9, font: bold, color: NAVY });
      y -= INITIALS_BLOCK_HEIGHT;
    }
    y -= CLAUSE_GAP;
  }

  const signatureRows = [
    ["Electronically signed by", input.signerName],
    ...(input.signerTitle ? [["Title", input.signerTitle]] : []),
    ["Typed electronic signature", input.typedSignature],
    ["Signed", formatTimestamp(input.signedAt)],
  ];
  const signatureHeight = 51 + signatureRows.reduce((total, [, value]) => total + pairHeight(value, bold), 0);
  if (!hasRoom(y, signatureHeight)) {
    ({ page, y } = addAgreementPage(pdf, input, regular, bold, true));
  }
  page.drawLine({ start: { x: LEFT_MARGIN, y }, end: { x: PAGE_WIDTH - RIGHT_MARGIN, y }, thickness: 1, color: NAVY });
  y -= 25;
  page.drawText("ELECTRONIC SIGNATURE", { x: LEFT_MARGIN, y, size: 11, font: bold, color: NAVY });
  y -= 25;
  for (const [label, value] of signatureRows) y = pair(page, label, value, y, regular, bold);

  const certificate = addPage(pdf, input, regular, bold, false);
  certificate.drawText("EXECUTION CERTIFICATE", { x: LEFT_MARGIN, y: 710, size: 19, font: bold, color: NAVY });
  certificate.drawLine({ start: { x: LEFT_MARGIN, y: 694 }, end: { x: PAGE_WIDTH - RIGHT_MARGIN, y: 694 }, thickness: 1.1, color: NAVY });
  let cy = 662;
  cy = drawWrapped(certificate, "This agreement was executed electronically through Truck Dispatch Pro. Electronic consent and all required clause acknowledgments were recorded before completion.", LEFT_MARGIN, cy, regular, 10, CONTENT_WIDTH, 15, NAVY) - 18;
  for (const [label, value] of [
    ["Signing ID", input.signingId], ["Template ID", input.templateId], ["Template version", String(input.templateVersion)],
    ["Agreement content hash", input.contentHash], ["Execution evidence hash", input.evidenceHash],
    ["Consent", "Electronic consent recorded"], ["Consent version", input.consentVersion],
    ["Consent accepted", formatTimestamp(input.consentAcceptedAt)], ["Signed", formatTimestamp(input.signedAt)],
  ]) cy = certificatePair(certificate, label, value, cy, regular, bold);

  const pages = pdf.getPages();
  pages.forEach((current, index) => drawFooter(current, index + 1, pages.length, regular));
  return pdf.save({ useObjectStreams: true });
}

function addAgreementPage(pdf: PDFDocument, input: ExecutedAgreementPdfInput, regular: PDFFont, bold: PDFFont, continuation: boolean) {
  const page = addPage(pdf, input, regular, bold, continuation);
  return { page, y: CONTENT_TOP };
}

function addPage(pdf: PDFDocument, input: ExecutedAgreementPdfInput, regular: PDFFont, bold: PDFFont, continuation: boolean) {
  const page = pdf.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
  page.drawText(input.templateName, { x: LEFT_MARGIN, y: HEADER_TITLE_Y, size: 8.5, font: bold, color: NAVY });
  page.drawText(continuation ? `Executed agreement - v${input.templateVersion}` : `Execution record - v${input.templateVersion}`, { x: LEFT_MARGIN, y: HEADER_SUBTITLE_Y, size: 7.5, font: regular, color: SLATE });
  page.drawLine({ start: { x: LEFT_MARGIN, y: HEADER_RULE_Y }, end: { x: PAGE_WIDTH - RIGHT_MARGIN, y: HEADER_RULE_Y }, thickness: 0.7, color: LIGHT });
  return page;
}

function hasRoom(y: number, height: number) { return y - height >= CONTENT_BOTTOM; }

function drawContinuationLabel(page: PDFPage, number: string, title: string, suffix: string, y: number, bold: PDFFont) {
  const lines = wrap(`${number}  ${title} (${suffix})`, bold, CONTINUATION_SIZE, CONTENT_WIDTH);
  return drawLines(page, lines, LEFT_MARGIN, y, bold, CONTINUATION_SIZE, CONTINUATION_LINE_HEIGHT, SLATE) - CONTINUATION_GAP;
}

function wrap(text: string, font: PDFFont, size: number, maxWidth: number): string[] {
  const lines: string[] = [];
  let line = "";
  for (const word of text.replace(/[\r\n]+/g, " ").trim().split(/\s+/)) {
    const next = line ? `${line} ${word}` : word;
    if (line && font.widthOfTextAtSize(next, size) > maxWidth) { lines.push(line); line = word; }
    else line = next;
  }
  if (line) lines.push(line);
  return lines.length ? lines : [""];
}

function wrapPreservingParagraphs(text: string, font: PDFFont, size: number, maxWidth: number) {
  return text.split(/\r?\n/).flatMap((paragraph, index) => [...(index ? [""] : []), ...wrap(paragraph, font, size, maxWidth)]);
}

function drawLines(page: PDFPage, lines: string[], x: number, y: number, font: PDFFont, size: number, lineHeight: number, color: ReturnType<typeof rgb>) {
  for (const line of lines) { page.drawText(line, { x, y, size, font, color }); y -= lineHeight; }
  return y;
}

function drawWrapped(page: PDFPage, text: string, x: number, y: number, font: PDFFont, size: number, maxWidth: number, lineHeight: number, color: ReturnType<typeof rgb>) {
  return drawLines(page, wrap(text, font, size, maxWidth), x, y, font, size, lineHeight, color);
}

function pair(page: PDFPage, label: string, value: string, y: number, regular: PDFFont, bold: PDFFont) {
  page.drawText(label, { x: LEFT_MARGIN, y, size: 7.5, font: regular, color: SLATE });
  const lines = wrap(value, bold, 10, PAGE_WIDTH - RIGHT_MARGIN - 205);
  drawLines(page, lines, 205, y, bold, 10, 13, NAVY);
  return y - Math.max(27, lines.length * 13 + 7);
}

function pairHeight(value: string, bold: PDFFont) {
  return Math.max(27, wrap(value, bold, 10, PAGE_WIDTH - RIGHT_MARGIN - 205).length * 13 + 7);
}

function certificatePair(page: PDFPage, label: string, value: string, y: number, regular: PDFFont, bold: PDFFont) {
  page.drawText(label.toUpperCase(), { x: LEFT_MARGIN, y, size: 7.2, font: bold, color: SLATE });
  const lines = wrap(value, regular, 8.7, PAGE_WIDTH - 215 - RIGHT_MARGIN);
  drawLines(page, lines, 215, y, regular, 8.7, 12, NAVY);
  return y - Math.max(25, lines.length * 12 + 7);
}

function drawFooter(pdfPage: PDFPage, pageNumber: number, total: number, font: PDFFont) {
  const text = `Executed Agreement  |  Page ${pageNumber} of ${total}`;
  pdfPage.drawLine({ start: { x: LEFT_MARGIN, y: FOOTER_RULE_Y }, end: { x: PAGE_WIDTH - RIGHT_MARGIN, y: FOOTER_RULE_Y }, thickness: 0.5, color: LIGHT });
  pdfPage.drawText(text, { x: LEFT_MARGIN, y: FOOTER_TEXT_Y, size: 7.2, font, color: SLATE });
}

function formatTimestamp(value: string) {
  return new Intl.DateTimeFormat("en-US", { dateStyle: "long", timeStyle: "long", timeZone: "UTC" }).format(new Date(value));
}
