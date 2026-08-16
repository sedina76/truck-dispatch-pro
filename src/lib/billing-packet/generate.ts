import "server-only";
import { PDFDocument, StandardFonts, rgb } from "pdf-lib";
import { createClient } from "@/lib/supabase/server";
import { getLatestDocument, type DocumentRow } from "@/lib/documents/latest-document";
import { computePodStatus } from "@/lib/documents/pod-status";

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

// Embeds an uploaded document's raw bytes as pages in the target packet.
// PDFs are merged page-for-page (never re-rendered); JPG/PNG become a
// single full-page image. The source object in Storage is only ever read,
// never modified -- this never writes back to load-documents.
async function appendDocumentPages(
  targetDoc: PDFDocument,
  bytes: ArrayBuffer,
  mimeType: string | null
): Promise<void> {
  if (mimeType === "application/pdf") {
    const srcDoc = await PDFDocument.load(bytes, { ignoreEncryption: true });
    const copiedPages = await targetDoc.copyPages(srcDoc, srcDoc.getPageIndices());
    copiedPages.forEach((p) => targetDoc.addPage(p));
    return;
  }

  const isPng = mimeType === "image/png";
  const image = isPng ? await targetDoc.embedPng(bytes) : await targetDoc.embedJpg(bytes);
  const page = targetDoc.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
  const maxW = PAGE_WIDTH - MARGIN * 2;
  const maxH = PAGE_HEIGHT - MARGIN * 2;
  const scale = Math.min(maxW / image.width, maxH / image.height, 1);
  const w = image.width * scale;
  const h = image.height * scale;
  page.drawImage(image, { x: (PAGE_WIDTH - w) / 2, y: (PAGE_HEIGHT - h) / 2, width: w, height: h });
}

export type GeneratedPacket = {
  bytes: Uint8Array;
  documentSnapshot: { document_id: string; document_type: string; created_at: string }[];
};

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
      .select("name, mc_number, dot_number, business_phone, business_email, address_line1, city, state, postal_code")
      .eq("id", invoice.organization_id)
      .single(),
    supabase.from("invoice_line_items").select("*").eq("invoice_id", invoiceId).order("sort_order"),
    invoice.load_id
      ? supabase
          .from("loads")
          .select("load_number, total_miles, load_stops(stop_type, facility_name, city, state, scheduled_at)")
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
    load_stops: { stop_type: string; facility_name: string | null; city: string | null; state: string | null; scheduled_at: string | null }[];
  } | null;
  const dispatchInfo = dispatchRes.data as unknown as {
    drivers: { first_name: string; last_name: string } | null;
    trucks: { unit_number: string } | null;
  } | null;
  const pickup = load?.load_stops.find((s) => s.stop_type === "pickup") ?? null;
  const delivery = load?.load_stops.find((s) => s.stop_type === "delivery") ?? null;

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
    if (delivery.scheduled_at) coverLine("Delivery Date", new Date(delivery.scheduled_at).toLocaleDateString());
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
  if (readiness.pod) {
    const bytes = await downloadDocumentBytes(supabase, readiness.pod.file_path);
    if (bytes) {
      await appendDocumentPages(packet, bytes, readiness.pod.mime_type);
      documentSnapshot.push({ document_id: readiness.pod.id, document_type: "pod", created_at: readiness.pod.created_at });
      includedLabels.push("Proof of Delivery (Verified)");
    }
  }

  // ---- Optional supporting documents, in order ------------------------------
  if (invoice.load_id) {
    for (const { type, label } of SUPPORTING_DOC_TYPES) {
      const doc = await getLatestDocument(supabase, "load", invoice.load_id, type);
      if (!doc) continue;
      const bytes = await downloadDocumentBytes(supabase, doc.file_path);
      if (!bytes) continue;
      await appendDocumentPages(packet, bytes, doc.mime_type);
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
  y -= 10;
  cover.drawText(`Total Amount Due: $${Number(invoice.total_amount).toLocaleString()}`, {
    x: MARGIN,
    y,
    size: 13,
    font: boldFont,
  });

  const bytes = await packet.save();
  return { bytes, documentSnapshot };
}

async function downloadDocumentBytes(
  supabase: Awaited<ReturnType<typeof createClient>>,
  storagePath: string
): Promise<ArrayBuffer | null> {
  const { data, error } = await supabase.storage.from("load-documents").download(storagePath);
  if (error || !data) return null;
  return data.arrayBuffer();
}
