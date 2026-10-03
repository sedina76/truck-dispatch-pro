import "server-only";
import { PDFDocument } from "pdf-lib";
import { createClient } from "@/lib/supabase/server";
import { getLatestDocument, type DocumentRow } from "@/lib/documents/latest-document";
import { computePodStatus } from "@/lib/documents/pod-status";
import { buildInvoiceDoc, drawInvoice, drawPacketCover, embedBrandFonts, PAGE_H, PAGE_W, pdfSafe } from "@/lib/documents/branded-pdf";
import { loadInvoiceSource } from "@/lib/invoices/pdf";

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
export async function appendDocumentPages(targetDoc: PDFDocument, bytes: ArrayBuffer, mimeType: string | null): Promise<AppendResult> {
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
    const page = targetDoc.addPage([PAGE_W, PAGE_H]);
    const maxW = PAGE_W - MARGIN * 2;
    const maxH = PAGE_H - MARGIN * 2;
    const scale = Math.min(maxW / image.width, maxH / image.height, 1);
    const w = image.width * scale;
    const h = image.height * scale;
    page.drawImage(image, { x: (PAGE_W - w) / 2, y: (PAGE_H - h) / 2, width: w, height: h });
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

// Builds the full merged packet: cover page, invoice page(s) (drawn directly,
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

  const source = await loadInvoiceSource(supabase, invoice, invoiceId);
  const packet = await PDFDocument.create();
  const fonts = await embedBrandFonts(packet);
  const documentSnapshot: GeneratedPacket["documentSnapshot"] = [];
  const includedLabels: string[] = ["Invoice"];

  // The cover page and invoice page(s) are drawn LAST (and inserted at the
  // front) because both list what's actually attached -- which is only
  // known once every document below has been read. Page order in the
  // finished packet is unchanged: cover, invoice, POD, supporting docs.

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

  // ---- Cover + invoice pages (branded layout, src/lib/documents/branded-pdf.ts)
  // Any document that could not be read is listed on the cover in a
  // "Could not include" box -- the one artifact guaranteed to reach whoever
  // generated or received the packet, regardless of what the calling UI
  // does with skippedDocuments.
  const invoiceDoc = buildInvoiceDoc({ ...source, documentsIncluded: includedLabels.filter((l) => l !== "Invoice") });
  const cover = packet.insertPage(0, [PAGE_W, PAGE_H]);
  drawPacketCover(cover, invoiceDoc, fonts, includedLabels, skippedDocuments);
  let insertAt = 1;
  drawInvoice(invoiceDoc, fonts, () => packet.insertPage(insertAt++, [PAGE_W, PAGE_H]));
  packet.setTitle(pdfSafe(`Billing packet ${invoice.invoice_number}`));

  const bytes = await packet.save();
  return { bytes, documentSnapshot, skippedDocuments };
}

export async function downloadDocumentBytes(
  supabase: Awaited<ReturnType<typeof createClient>>,
  storagePath: string
): Promise<ArrayBuffer | null> {
  const { data, error } = await supabase.storage.from("load-documents").download(storagePath);
  if (error || !data) return null;
  return data.arrayBuffer();
}
