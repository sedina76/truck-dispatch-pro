import { redirect } from "next/navigation";
import { requireRoleForApi } from "@/lib/auth/require-role";
import { CarrierW9ResourceNotFoundError, getCarrierW9SignedUrlOrThrow } from "@/lib/carrier-w9/signed-url";

// Staff-side secure W-9 route (2N.2 section 19). Owner/Admin/Accountant
// only -- Dispatcher/Viewer get a generic 404 here even though they can
// see W-9 status elsewhere; requireRoleForApi() is the first line of
// defense, getCarrierW9SignedUrlOrThrow() independently re-checks role
// AND organization AND status/artifact presence before ever creating a
// signed URL. NOT YET LIVE: depends on migration 0099 (not applied).
export async function GET(request: Request, { params }: { params: Promise<{ id: string; w9Id: string }> }) {
  const denied = await requireRoleForApi(["owner", "admin", "accountant"]);
  if (denied) return denied;
  const { w9Id } = await params;
  const download = new URL(request.url).searchParams.get("download") === "1";
  try {
    const { url } = await getCarrierW9SignedUrlOrThrow(w9Id, download);
    redirect(url);
  } catch (error) {
    if (error instanceof CarrierW9ResourceNotFoundError) return new Response("Not Found", { status: 404 });
    throw error;
  }
}
