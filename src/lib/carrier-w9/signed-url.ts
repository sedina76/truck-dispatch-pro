import "server-only";

import { getCurrentOrgId } from "@/lib/actions/records";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { W9_BUCKET, w9StoragePath } from "./types";

export class CarrierW9ResourceNotFoundError extends Error {
  constructor() {
    super("W-9 not found.");
  }
}

// Secure View/Download role policy (2N.2 section 19): Owner/Admin/
// Accountant only from the staff application -- Dispatcher/Viewer/Driver
// get NO PDF access at all (they may see status/masked TIN elsewhere, but
// never reach this function's caller; the route below independently
// re-checks role itself, this is not the only enforcement point).
const DOWNLOAD_ROLES = new Set(["owner", "admin", "accountant"]);

// 2N.3A repair: two deliberately separate trust levels, never blurred.
//
// A. The request-scoped, RLS-bound authenticated client (`supabase` below)
//    is the ONLY thing that ever resolves who is asking: session identity,
//    role, org membership, and the W-9 row itself (including its org_id,
//    status, and recorded storage path) are all read through it, exactly
//    as before this repair -- a caller who fails any of those checks never
//    reaches step B at all, and nothing the caller supplies (w9Id is the
//    only input) ever reaches Storage directly.
//
// B. `carrier-w9s` intentionally has NO authenticated storage.objects
//    policy (0099's own header comment: "every read/write goes through
//    the service-role client from a trusted server action/route"). The
//    defect this repair fixes was that this function was the one place
//    that promise wasn't kept -- it called Storage through the
//    authenticated client, which Storage's own RLS check then silently
//    denied (surfaced as a generic "Object not found", not a permission
//    error). The service-role client is used ONLY for the single
//    createSignedUrl() call below, ONLY after every check in A has
//    already passed, and ONLY with the server-derived/validated path --
//    never as a substitute for A's authorization, and never exposed to
//    the browser (a signed URL is handed back, not the service-role
//    client itself).
export async function getCarrierW9SignedUrlOrThrow(w9Id: string, download: boolean): Promise<{ url: string; filename: string }> {
  const supabase = await createClient();
  const [{ data: { user } }, { data: role }] = await Promise.all([supabase.auth.getUser(), supabase.rpc("current_role")]);
  if (!user || !DOWNLOAD_ROLES.has(String(role))) throw new CarrierW9ResourceNotFoundError();

  const organizationId = await getCurrentOrgId();
  const { data } = await supabase
    .from("carrier_w9s")
    .select("id, organization_id, version, status, generated_storage_path, generated_pdf_sha256")
    .eq("id", w9Id)
    .maybeSingle();
  if (!data || data.organization_id !== organizationId || !["completed", "superseded"].includes(data.status) || !data.generated_storage_path || !data.generated_pdf_sha256) {
    // Generic not-found for foreign-org, random UUID, draft, voided, and
    // failed alike -- no existence leak (2N.2 section 19/25).
    throw new CarrierW9ResourceNotFoundError();
  }

  const expected = w9StoragePath(data);
  if (data.generated_storage_path !== expected) throw new Error("W-9 storage path is invalid.");
  const filename = `w9-v${data.version}.pdf`;

  // Step B: service-role, read-only, single call, server-validated path only.
  const service = createServiceRoleClient();
  const { data: signed, error } = await service.storage.from(W9_BUCKET).createSignedUrl(expected, 300, download ? { download: filename } : undefined);
  if (error || !signed) throw new Error("Could not create a secure W-9 link.");
  return { url: signed.signedUrl, filename };
}
