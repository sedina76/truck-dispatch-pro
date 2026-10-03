import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { requireRoleForApi, BILLING_ROLES } from "@/lib/auth/require-role";
import { loadIssuedCarrierInvoice, renderCarrierFactorPackage } from "@/lib/carrier-invoices/pdf";
import { saveCarrierPacket, signedPacketUrl } from "@/lib/carrier-invoices/packet-storage";

// The billing packet for a carrier's invoice: cover, the carrier's invoice,
// then each load's proof of delivery, rate confirmation, BOL and accessorial
// documents -- the same file the email attaches.
//
// Phone photos make this file large, and a response straight from the server
// is capped (~4.5 MB on Vercel), so -- like your own invoice's billing packet
// -- the file is saved to the private billing-packets bucket (org folder,
// owner/admin/accountant only) and opened through a short-lived signed link.
// Older copies of this invoice's packet are removed after a new one is saved
// (lib/carrier-invoices/packet-storage.ts, shared with Generate Billing Packet).
// Route handlers are not wrapped by the segment layout, so roles are checked here; RLS scopes the invoice.
export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const denied = await requireRoleForApi(BILLING_ROLES);
  if (denied) return denied;
  const { id } = await params;
  const supabase = await createClient();
  const inv = await loadIssuedCarrierInvoice(supabase, id);
  if (!inv) return new NextResponse("Issued carrier invoice not found.", { status: 404 });
  let bytes: Uint8Array;
  try {
    bytes = (await renderCarrierFactorPackage(supabase, inv)).bytes;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("[carrier-invoice-package] could not render:", { invoice_id: id, error: message });
    return new NextResponse(message.startsWith("The package is not ready") || message.startsWith("Could not include") ? message : "Could not generate the PDF.", { status: message.startsWith("The package is not ready") ? 409 : 500 });
  }

  const download = new URL(req.url).searchParams.get("download") === "1";
  const safe = inv.snapshot.invoice_number.replace(/[^A-Za-z0-9-]/g, "");
  const filename = `billing-packet-${safe}.pdf`;

  const { data: org } = await supabase.rpc("current_org_id");
  if (org) {
    const saved = await saveCarrierPacket(supabase, String(org), id, bytes, filename);
    if ("path" in saved) {
      const url = await signedPacketUrl(supabase, saved.path, download);
      if (url) return NextResponse.redirect(url, 303);
    } else {
      console.error("[carrier-invoice-package] could not save the packet:", { invoice_id: id, error: saved.error });
    }
  }

  // Fallback: send the file directly (fine for small packets).
  return new NextResponse(Buffer.from(bytes), {
    headers: {
      "Content-Type": "application/pdf",
      "Content-Disposition": `${download ? "attachment" : "inline"}; filename="${filename}"`,
      "Cache-Control": "private, no-store",
    },
  });
}
