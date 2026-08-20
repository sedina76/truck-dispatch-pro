import "server-only";
import { PDFDocument, StandardFonts, rgb } from "pdf-lib";
import { createClient } from "@/lib/supabase/server";
import { getLatestDocument, type DocumentRow } from "@/lib/documents/latest-document";
import { computePodStatus } from "@/lib/documents/pod-status";
import { formatStopDateTime } from "@/lib/timezone/format";
import { resolveStopTimezone } from "@/lib/timezone/resolve";

const PAGE_WIDTH = 612; // US Letter, points
const PAGE_HEIGHT = 792;
const MARGIN = 54;

// Non-blocking accessorial/supporting document types included in the
// packet when present, in the order requested. POD is handled separately
// (it's required and goes first); rate confirmation and BOL are the next
// most common, then the accessorials.
const SUPPORTING_DOC_TYPES = [
  { type: "rate_confirmation", label: "Rate Confirmation" },
  { type: "bol", label: "Bill of Lading" },
  { type: "lumper_receipt", label: "Lumper Receipt" },
  { type: "detention_document", label: "Detention Documentation" },
  { type: "scale_ticket", label: "Scale Ticket" },
  { type: "other", label: "Other Supporting Document" },
] as const;

export type PacketReadiness = {
  ready: boolean;
  missing: string[];
  pod: DocumentRow | null;
};

// The one hard requirement, mirroring check_invoice_ready_to_send()
// (0023_pod_workflow.sql) exactly -- packet readiness and invoice-send
// readiness must never disagree about what "ready" means.
export async function checkPacketReadiness(
  supabase: Awaited<ReturnType<typeof createClient>>,
  loadId: string | null
): Promise<PacketReadiness> {
  if (!loadId) {
    return { ready: false, missing: ["This invoice is not linked to a load."], pod: null };
  }
  const pod = await getLatestDocument(supabase, "load", loadId, "pod");
  const podStatus = computePodStatus(pod);
  const missing: string[] = [];
  if (podStatus !== "verified") missing.push("Verified Proof of Delivery");
  return { ready: missing.length === 0, missing, pod };
}

function drawWrappedText(
  page: import("pdf-lib").PDFPage,
  text: string,
  x: number,
  y: number,
  options: { font: import("pdf-lib").PDFFont; size: number; maxWidth: number; lineHeight: number; color?: ReturnType<typeof rgb> }
) {
  const words = text.split(" ");
  let line = "";
  let cursorY = y;
  for (const word of words) {
    const testLine = line ? `${line} ${word}` : word;
    if (options.font.widthOfTextAtSize(testLine, options.size) > options.maxWidth && line) {
      page.drawText(line, { x, y: cursorY, size: options.size, font: options.font, color: options.color ?? rgb(0, 0, 0) });
      line = word;
      cursorY -= options.lineHeight;
    } else {
      line = testLine;
    }
  }
  if (line) page.drawText(line, { x, y: cursorY, size: options.size, font: options.font, color: options.color ?? rgb(0, 0, 0) });
  return cursorY - options.lineHeight;
}

export type AppendResult = { ok: true } | { ok: false; reason: string };

// Embeds an uploaded document's raw bytes as pages in the target packet.
// PDFs are merged page-for-page (never re-rendered); JPG/PNG become a
// single full-page image. The source object in Storage is only ever read,
// never modified -- this never writes back to load-documents.
//
// Defensive by construction, not by accident: a live crash (TypeError:
// Cannot read properties of undefined (reading 'Pages')) showed that
// PDFDocument.load() can succeed -- the file parses enough to return a
// PDFDocument -- while the page tree it parsed into is malformed/
// incompatible enough that pdf-lib throws internally the moment
// getPageIndices()/copyPages() actually walks it. Both calls, and the
// image-embed path, are wrapped separately so ANY failure becomes a typed
// AppendResult instead of an uncaught exception -- this function must
// never throw. The caller (generateBillingPacket) decides what a failure
// MEANS (required POD vs. optional supporting document), which is a
// business decision, not this function's job.
async function appendDocumentPages(targetDoc: PDFDocument, bytes: ArrayBuffer, mimeType: string | null): Promise<AppendResult> {
  if (mimeType === "application/pdf") {
    let srcDoc: PDFDocument;
    try {
      srcDoc = await PDFDocument.load(bytes, { ignoreEncryption: true });
    } catch (err) {
      return { ok: false, reason: `could not parse the PDF (${err instanceof Error ? err.message : "unknown error"})` };
    }

    let pageIndices: number[];
    let copiedPages: Awaited<ReturnType<PDFDocument["copyPages"]>>;
    try {
      // The exact call site that crashed live: a malformed/incompatible
      // internal page tree makes pdf-lib throw here even though load()
      // above already returned successfully.
      pageIndices = srcDoc.getPageIndices();
      if (pageIndices.length === 0) {
        return { ok: false, reason: "the PDF has zero pages" };
      }
      copiedPages = await targetDoc.copyPages(srcDoc, pageIndices);
    } catch (err) {
      return { ok: false, reason: `the PDF's page structure is invalid or unsupported (${err instanceof Error ? err.message : "unknown error"})` };
    }

    copiedPages.forEach((p) => targetDoc.addPage(p));
    return { ok: true };
  }

  // Image attachments -- same defensive wrapping for symmetry (a
  // corrupted JPG/PNG must not crash the packet either), valid-image
  // handling below is otherwise unchanged.
  try {
    const isPng = mimeType === "image/png";
    const image = isPng ? await targetDoc.embedPng(bytes) : await targetDoc.embedJpg(bytes);
    const page = targetDoc.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
    const maxW = PAGE_WIDTH - MARGIN * 2;
    const maxH = PAGE_HEIGHT - MARGIN * 2;
    const scale = Math.min(maxW / image.width, maxH / image.height, 1);
    const w = image.width * scale;
    const h = image.height * scale;
    page.drawImage(image, { x: (PAGE_WIDTH - w) / 2, y: (PAGE_HEIGHT - h) / 2, width: w, height: h });
    return { ok: true };
  } catch (err) {
    return { ok: false, reason: `could not read the image (${err instanceof Error ? err.message : "unknown error"})` };
  }
}

export type GeneratedPacket = {
  bytes: Uint8Array;
  documentSnapshot: { document_id: string; document_type: string; created_at: string }[];
  // Optional supporting documents that were skipped because their file
  // could not be read (spec: "surface a warning", never silently omit).
  // Also written onto the packet's own cover page (see below) so the
  // warning survives regardless of what the calling UI does with it.
  skippedDocuments: { label: string; filename: string; reason: string }[];
};

// Logs enough to locate the bad document without ever logging file
// contents/secrets -- id, filename, mime type, and invoice/load id only.
function logAppendFailure(context: { invoiceId: string; loadId: string | null; documentId: string; filename: string; mimeType: string | null; label: string; reason: string }) {
  console.error("[billing-packet] could not include a document in the packet:", {
    invoice_id: context.invoiceId,
    load_id: context.loadId,
    document_id: context.documentId,
    filename: context.filename,
    mime_type: context.mimeType,
    label: context.label,
    reason: context.reason,
  });
}

// Builds the full merged packet: cover page, invoice page (drawn directly,
// not re-using the browser-print /invoices/[id]/pdf view, since this must
// run server-side without a browser), then verified POD, then whichever
// optional supporting documents are on file, in the requested order.
export async function generateBillingPacket(invoiceId: string): Promise<GeneratedPacket> {
  const supabase = await createClient();

  const { data: invoice, error: invoiceError } = await supabase.from("invoices").select("*").eq("id", invoiceId).single();
  if (invoiceError || !invoice) throw new Error("Invoice not found.");

  const readiness = await checkPacketReadiness(supabase, invoice.load_id);
  if (!readiness.ready) {
    throw new Error(`Billing packet not ready. Missing: ${readiness.missing.join(", ")}`);
  }

  const [{ data: org }, { data: lineItems }, loadRes, dispatchRes] = await Promise.all([
    supabase
      .from("organizations")
      .select("name, mc_number, dot_number, business_phone, business_email, address_line1, city, state, postal_code, timezone")
      .eq("id", invoice.organization_id)
      .single(),
    supabase.from("invoice_line_items").select("*").eq("invoice_id", invoiceId).order("sort_order"),
    invoice.load_id
      ? supabase
          .from("loads")
          .select("load_number, total_miles, load_stops(stop_type, facility_name, city, state, scheduled_at, timezone)")
          .eq("id", invoice.load_id)
          .single()
      : Promise.resolve({ data: null }),
    invoice.dispatch_id
      ? supabase.from("dispatches").select("drivers(first_name, last_name), trucks(unit_number)").eq("id", invoice.dispatch_id).single()
      : Promise.resolve({ data: null }),
  ]);

  const load = loadRes.data as unknown as {
    load_number: string;
    total_miles: number | null;
    load_stops: { stop_type: string; facility_name: string | null; city: string | null; state: string | null; scheduled_at: string | null; timezone: string | null }[];
  } | null;
  const dispatchInfo = dispatchRes.data as unknown as {
    drivers: { first_name: string; last_name: string } | null;
    trucks: { unit_number: string } | null;
  } | null;
  const pickup = load?.load_stops.find((s) => s.stop_type === "pickup") ?? null;
  const delivery = load?.load_stops.find((s) => s.stop_type === "delivery") ?? null;
  const deliveryTz = resolveStopTimezone(delivery?.timezone ?? null, org?.timezone ?? null).timezone;

  const packet = await PDFDocument.create();
  const font = await packet.embedFont(StandardFonts.Helvetica);
  const boldFont = await packet.embedFont(StandardFonts.HelveticaBold);

  // ---- Cover page --------------------------------------------------------
  const documentSnapshot: GeneratedPacket["documentSnapshot"] = [];
  const includedLabels: string[] = ["Invoice"];
  const cover = packet.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
  let y = PAGE_HEIGHT - MARGIN;
  cover.drawText("BILLING PACKET", { x: MARGIN, y, size: 24, font: boldFont, color: rgb(0.1, 0.1, 0.15) });
  y -= 40;
  cover.drawText(org?.name ?? "Your Company", { x: MARGIN, y, size: 14, font: boldFont });
  y -= 30;

  const coverLine = (label: string, value: string) => {
    cover.drawText(label, { x: MARGIN, y, size: 10, font, color: rgb(0.45, 0.45, 0.45) });
    cover.drawText(value, { x: MARGIN + 160, y, size: 11, font: boldFont });
    y -= 20;
  };
  coverLine("Invoice #", invoice.invoice_number);
  coverLine("Load #", load?.load_number ?? "--");
  coverLine("Bill To", invoice.bill_to_name);
  if (pickup) coverLine("Pickup", [pickup.facility_name, pickup.city, pickup.state].filter(Boolean).join(", ") || "--");
  if (delivery) {
    coverLine("Delivery", [delivery.facility_name, delivery.city, delivery.state].filter(Boolean).join(", ") || "--");
    if (delivery.scheduled_at) coverLine("Delivery Date", formatStopDateTime(delivery.scheduled_at, deliveryTz, { dateOnly: true, includeYear: true }));
  }
  coverLine("Invoice Amount", `$${Number(invoice.total_amount).toLocaleString()}`);

  y -= 15;
  cover.drawText("Documents Included:", { x: MARGIN, y, size: 11, font: boldFont });
  y -= 22;

  // ---- Invoice page -------------------------------------------------------
  const invoicePage = packet.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
  let iy = PAGE_HEIGHT - MARGIN;
  invoicePage.drawText("INVOICE", { x: MARGIN, y: iy, size: 20, font: boldFont });
  invoicePage.drawText(invoice.invoice_number, { x: PAGE_WIDTH - MARGIN - 120, y: iy, size: 12, font: boldFont });
  iy -= 30;
  invoicePage.drawText(org?.name ?? "Your Company", { x: MARGIN, y: iy, size: 11, font: boldFont });
  iy -= 30;
  invoicePage.drawText("Bill To:", { x: MARGIN, y: iy, size: 9, font, color: rgb(0.5, 0.5, 0.5) });
  iy -= 14;
  invoicePage.drawText(invoice.bill_to_name, { x: MARGIN, y: iy, size: 11, font: boldFont });
  iy -= 30;

  invoicePage.drawText("Description", { x: MARGIN, y: iy, size: 9, font: boldFont });
  invoicePage.drawText("Qty", { x: 360, y: iy, size: 9, font: boldFont });
  invoicePage.drawText("Unit Price", { x: 420, y: iy, size: 9, font: boldFont });
  invoicePage.drawText("Amount", { x: 500, y: iy, size: 9, font: boldFont });
  iy -= 16;
  for (const li of lineItems ?? []) {
    iy = drawWrappedText(invoicePage, String(li.description), MARGIN, iy, { font, size: 9, maxWidth: 290, lineHeight: 12 }) + 12;
    invoicePage.drawText(String(Number(li.quantity)), { x: 360, y: iy, size: 9, font });
    invoicePage.drawText(`$${Number(li.unit_price).toLocaleString()}`, { x: 420, y: iy, size: 9, font });
    invoicePage.drawText(`$${Number(li.line_total).toLocaleString()}`, { x: 500, y: iy, size: 9, font });
    iy -= 18;
  }

  iy -= 12;
  invoicePage.drawText(`Subtotal: $${Number(invoice.subtotal_amount).toLocaleString()}`, { x: 400, y: iy, size: 10, font });
  iy -= 16;
  invoicePage.drawText(`TOTAL DUE: $${Number(invoice.total_amount).toLocaleString()}`, { x: 400, y: iy, size: 12, font: boldFont });

  if (dispatchInfo?.drivers || dispatchInfo?.trucks) {
    iy -= 40;
    invoicePage.drawText("Load Details:", { x: MARGIN, y: iy, size: 9, font: boldFont, color: rgb(0.5, 0.5, 0.5) });
    iy -= 14;
    if (load?.total_miles) {
      invoicePage.drawText(`Miles: ${Number(load.total_miles).toLocaleString()}`, { x: MARGIN, y: iy, size: 9, font });
      iy -= 14;
    }
    if (dispatchInfo?.trucks) {
      invoicePage.drawText(`Truck: ${dispatchInfo.trucks.unit_number}`, { x: MARGIN, y: iy, size: 9, font });
      iy -= 14;
    }
  }

  // ---- POD (required, already confirmed verified) --------------------------
  // Required, not optional: the packet has no meaning without it (spec:
  // "Do not silently omit required POD... docs without telling the
  // user"). Both a download failure and an appendDocumentPages failure
  // now THROW a clean business error instead of either crashing
  // (the original bug) or silently producing an "ready"-looking packet
  // that's actually missing its one hard requirement.
  const skippedDocuments: GeneratedPacket["skippedDocuments"] = [];
  if (readiness.pod) {
    const bytes = await downloadDocumentBytes(supabase, readiness.pod.file_path);
    if (!bytes) {
      logAppendFailure({ invoiceId, loadId: invoice.load_id, documentId: readiness.pod.id, filename: readiness.pod.file_name, mimeType: readiness.pod.mime_type, label: "Proof of Delivery", reason: "could not download the file from storage" });
      throw new Error(`Could not include the Proof of Delivery (${readiness.pod.file_name}): the file could not be read from storage. Please re-upload it and try again.`);
    }
    const result = await appendDocumentPages(packet, bytes, readiness.pod.mime_type);
    if (!result.ok) {
      logAppendFailure({ invoiceId, loadId: invoice.load_id, documentId: readiness.pod.id, filename: readiness.pod.file_name, mimeType: readiness.pod.mime_type, label: "Proof of Delivery", reason: result.reason });
      throw new Error(`Could not include the Proof of Delivery (${readiness.pod.file_name}): the PDF is invalid or unsupported. Please re-upload a valid file and try again.`);
    }
    documentSnapshot.push({ document_id: readiness.pod.id, document_type: "pod", created_at: readiness.pod.created_at });
    includedLabels.push("Proof of Delivery (Verified)");
  }

  // ---- Optional supporting documents, in order ------------------------------
  // Non-blocking: a malformed rate confirmation/BOL/etc. does not stop the
  // packet (POD above is the only hard requirement, matching this
  // module's existing readiness model) -- but it is never silently
  // dropped either. It's recorded in skippedDocuments (surfaced to the
  // caller) AND written directly onto the packet's own cover page below,
  // so the warning is visible in the one artifact guaranteed to reach
  // whoever generated or received it, regardless of what the calling UI
  // does with the return value.
  if (invoice.load_id) {
    for (const { type, label } of SUPPORTING_DOC_TYPES) {
      const doc = await getLatestDocument(supabase, "load", invoice.load_id, type);
      if (!doc) continue;
      const bytes = await downloadDocumentBytes(supabase, doc.file_path);
      if (!bytes) {
        logAppendFailure({ invoiceId, loadId: invoice.load_id, documentId: doc.id, filename: doc.file_name, mimeType: doc.mime_type, label, reason: "could not download the file from storage" });
        skippedDocuments.push({ label, filename: doc.file_name, reason: "could not be downloaded from storage" });
        continue;
      }
      const result = await appendDocumentPages(packet, bytes, doc.mime_type);
      if (!result.ok) {
        logAppendFailure({ invoiceId, loadId: invoice.load_id, documentId: doc.id, filename: doc.file_name, mimeType: doc.mime_type, label, reason: result.reason });
        skippedDocuments.push({ label, filename: doc.file_name, reason: result.reason });
        continue;
      }
      documentSnapshot.push({ document_id: doc.id, document_type: type, created_at: doc.created_at });
      includedLabels.push(label);
    }
  }

  // Finish the cover page's checklist now that we know what was actually included.
  // Plain ASCII "-" rather than "✓" (U+2713): pdf-lib's StandardFonts only
  // support WinAnsi encoding, which has no glyph for the Unicode checkmark
  // -- drawText() throws "WinAnsi cannot encode ..." the instant a packet
  // with any included document is generated. This is the same plain-ASCII
  // convention already used everywhere else in this file/module ("--"
  // instead of an em dash, "->" instead of an arrow) -- applied here too,
  // not a new rule.
  for (const label of includedLabels) {
    cover.drawText(`- ${label}`, { x: MARGIN, y, size: 10, font, color: rgb(0.06, 0.5, 0.35) });
    y -= 16;
  }

  // Warning surfaced directly on the cover page (spec: "surfacing a
  // warning", never silent) -- this is the one artifact guaranteed to
  // reach whoever generated or received the packet, regardless of
  // whether the calling UI does anything with skippedDocuments itself.
  if (skippedDocuments.length > 0) {
    y -= 8;
    cover.drawText("Could Not Include:", { x: MARGIN, y, size: 10, font: boldFont, color: rgb(0.6, 0.35, 0.05) });
    y -= 16;
    for (const skipped of skippedDocuments) {
      y = drawWrappedText(cover, `- ${skipped.label} (${skipped.filename}): ${skipped.reason}`, MARGIN, y, { font, size: 9, maxWidth: PAGE_WIDTH - MARGIN * 2, lineHeight: 12, color: rgb(0.6, 0.35, 0.05) }) + 4;
    }
  }

  y -= 10;
  cover.drawText(`Total Amount Due: $${Number(invoice.total_amount).toLocaleString()}`, {
    x: MARGIN,
    y,
    size: 13,
    font: boldFont,
  });

  const bytes = await packet.save();
  return { bytes, documentSnapshot, skippedDocuments };
}

async function downloadDocumentBytes(
  supabase: Awaited<ReturnType<typeof createClient>>,
  storagePath: string
): Promise<ArrayBuffer | null> {
  const { data, error } = await supabase.storage.from("load-documents").download(storagePath);
  if (error || !data) return null;
  return data.arrayBuffer();
}
