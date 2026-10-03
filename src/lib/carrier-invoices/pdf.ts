import "server-only";
import { PDFDocument } from "pdf-lib";
import { createClient } from "@/lib/supabase/server";
import { buildInvoiceDoc, drawInvoice, drawPacketCover, embedBrandFonts, PAGE_H, PAGE_W, pdfSafe } from "@/lib/documents/branded-pdf";
import { getLatestDocument } from "@/lib/documents/latest-document";
import { computePodStatus } from "@/lib/documents/pod-status";
import { appendDocumentPages, downloadDocumentBytes } from "@/lib/billing-packet/generate";
import { carrierInvoiceSource, type CarrierInvoiceSnapshot, type FactorContact } from "./source";

type Supabase = Awaited<ReturnType<typeof createClient>>;

export type IssuedCarrierInvoice = {
  id: string;
  carrierId: string;
  issuanceStatus: string;
  paymentStatus: string;
  amountPaid: number;
  snapshot: CarrierInvoiceSnapshot;
  factor: FactorContact;
};

/** An ISSUED carrier freight invoice with its immutable snapshot, read through the caller's RLS. Null if not found / not issued. */
export async function loadIssuedCarrierInvoice(supabase: Supabase, id: string): Promise<IssuedCarrierInvoice | null> {
  const { data: inv } = await supabase
    .from("carrier_invoices")
    .select("id, carrier_id, invoice_document_type, issuance_status, payment_status, amount_paid")
    .eq("id", id)
    .maybeSingle();
  if (!inv || inv.invoice_document_type !== "carrier_freight_invoice") return null;
  const { data: snap } = await supabase.from("carrier_invoice_issuance_snapshots").select("snapshot_payload").eq("invoice_id", id).maybeSingle();
  if (!snap) return null;
  const raw = snap.snapshot_payload as CarrierInvoiceSnapshot & { factoring?: { factoring_company_id?: string | null } | null };
  // The issued snapshot stores its loads as "source_loads" (0146, schema 2);
  // everything here reads "loads". Without this the billing packet had no
  // loads to fetch documents for (invoice-only packet) and the PDF/email had
  // no load numbers.
  const payload = { ...raw, loads: raw.loads ?? raw.source_loads ?? [] };
  let factor: FactorContact = null;
  const companyId = payload.factoring?.factoring_company_id;
  if (companyId) {
    const { data: co } = await supabase.from("factoring_companies").select("address_line1, city, state, postal_code, phone, email").eq("id", companyId).maybeSingle();
    if (co) {
      const cityLine = [co.city, [co.state, co.postal_code].filter(Boolean).join(" ")].filter((s) => s && String(s).trim()).join(", ");
      factor = { address: [co.address_line1, cityLine].filter((s) => s && String(s).trim()).join("\n") || null, phone: co.phone ?? null, email: co.email ?? null };
    }
  }
  return {
    id: String(inv.id),
    carrierId: String(inv.carrier_id),
    issuanceStatus: String(inv.issuance_status),
    paymentStatus: String(inv.payment_status),
    amountPaid: Number(inv.amount_paid ?? 0),
    snapshot: payload,
    factor,
  };
}

export async function renderCarrierInvoicePdf(inv: IssuedCarrierInvoice): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  const fonts = await embedBrandFonts(pdf);
  drawInvoice(buildInvoiceDoc(carrierInvoiceSource(inv.snapshot, inv.factor, inv.amountPaid)), fonts, () => pdf.addPage([PAGE_W, PAGE_H]));
  pdf.setTitle(pdfSafe(`Invoice ${inv.snapshot.invoice_number}`));
  return pdf.save();
}

const SUPPORTING = [
  { type: "rate_confirmation", label: "Rate Confirmation" },
  { type: "bol", label: "Bill of Lading" },
  { type: "lumper_receipt", label: "Lumper Receipt" },
  { type: "detention_document", label: "Detention Documentation" },
  { type: "scale_ticket", label: "Scale Ticket" },
] as const;

/** Every load on the invoice needs a VERIFIED proof of delivery -- factors will not buy an invoice without it. */
export async function factorPackageMissing(supabase: Supabase, inv: IssuedCarrierInvoice): Promise<string[]> {
  const missing: string[] = [];
  if ((inv.snapshot.loads ?? []).length === 0) return ["the invoice's loads (none found on the issued invoice)"];
  for (const l of inv.snapshot.loads ?? []) {
    const pod = await getLatestDocument(supabase, "load", l.load_id, "pod");
    if (computePodStatus(pod) !== "verified") missing.push(`Load ${l.load_number}: verified proof of delivery`);
  }
  return missing;
}

/**
 * The factor package: cover, the carrier's invoice, then for each load its
 * proof of delivery (required) followed by the rate confirmation, bill of
 * lading and any accessorial documents on file. A supporting document that
 * cannot be read is listed on the cover, never silently dropped.
 */
export async function renderCarrierFactorPackage(supabase: Supabase, inv: IssuedCarrierInvoice): Promise<{ bytes: Uint8Array; skipped: { label: string; filename: string; reason: string }[] }> {
  const missing = await factorPackageMissing(supabase, inv);
  if (missing.length) throw new Error(`The package is not ready. Missing: ${missing.join("; ")}.`);
  const pkg = await PDFDocument.create();
  const fonts = await embedBrandFonts(pkg);
  const included: string[] = ["Invoice"];
  const skipped: { label: string; filename: string; reason: string }[] = [];
  const many = (inv.snapshot.loads ?? []).length > 1;

  for (const l of inv.snapshot.loads ?? []) {
    const tag = many ? ` (Load ${l.load_number})` : "";
    const pod = await getLatestDocument(supabase, "load", l.load_id, "pod");
    const podBytes = pod ? await downloadDocumentBytes(supabase, pod.file_path) : null;
    const podResult = podBytes && pod ? await appendDocumentPages(pkg, podBytes, pod.mime_type) : { ok: false as const, reason: "could not be read from storage" };
    if (!podResult.ok) throw new Error(`Could not include the proof of delivery for load ${l.load_number} (${pod?.file_name ?? "file"}): ${podResult.reason}. Please re-upload it and try again.`);
    included.push(`Proof of Delivery${tag}`);
    for (const { type, label } of SUPPORTING) {
      const doc = await getLatestDocument(supabase, "load", l.load_id, type);
      if (!doc) continue;
      const bytes = await downloadDocumentBytes(supabase, doc.file_path);
      const result = bytes ? await appendDocumentPages(pkg, bytes, doc.mime_type) : { ok: false as const, reason: "could not be read from storage" };
      if (!result.ok) {
        skipped.push({ label: `${label}${tag}`, filename: doc.file_name, reason: result.reason });
        continue;
      }
      included.push(`${label}${tag}`);
    }
  }

  const doc = buildInvoiceDoc({ ...carrierInvoiceSource(inv.snapshot, inv.factor, inv.amountPaid), documentsIncluded: included.filter((x) => x !== "Invoice") });
  drawPacketCover(pkg.insertPage(0, [PAGE_W, PAGE_H]), doc, fonts, included, skipped);
  let at = 1;
  drawInvoice(doc, fonts, () => pkg.insertPage(at++, [PAGE_W, PAGE_H]));
  pkg.setTitle(pdfSafe(`Invoice package ${inv.snapshot.invoice_number}`));
  return { bytes: await pkg.save(), skipped };
}
