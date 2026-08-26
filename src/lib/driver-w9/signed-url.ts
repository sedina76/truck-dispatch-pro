import "server-only";

import { getCurrentOrgId } from "@/lib/actions/records";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { DRIVER_W9_BUCKET, driverW9StoragePath } from "./types";

export class DriverW9ResourceNotFoundError extends Error {
  constructor() {
    super("W-9 not found.");
  }
}

// Mirrors src/lib/carrier-w9/signed-url.ts exactly, including its own
// two-trust-level structure (A: authenticated client resolves who's
// asking and validates the row; B: service-role client used only for the
// single createSignedUrl() call, only after A passes, only with the
// server-derived path). Same role tier as carrier W-9 -- owner/admin/
// accountant only; dispatcher/viewer/driver never reach Storage.
const DOWNLOAD_ROLES = new Set(["owner", "admin", "accountant"]);

export async function getDriverW9SignedUrlOrThrow(w9Id: string, download: boolean): Promise<{ url: string; filename: string }> {
  const supabase = await createClient();
  const [{ data: { user } }, { data: role }] = await Promise.all([supabase.auth.getUser(), supabase.rpc("current_role")]);
  if (!user || !DOWNLOAD_ROLES.has(String(role))) throw new DriverW9ResourceNotFoundError();

  const organizationId = await getCurrentOrgId();
  const { data } = await supabase
    .from("driver_w9s")
    .select("id, organization_id, version, status, generated_storage_path, generated_pdf_sha256")
    .eq("id", w9Id)
    .maybeSingle();
  if (!data || data.organization_id !== organizationId || !["completed", "superseded"].includes(data.status) || !data.generated_storage_path || !data.generated_pdf_sha256) {
    throw new DriverW9ResourceNotFoundError();
  }

  const expected = driverW9StoragePath(data);
  if (data.generated_storage_path !== expected) throw new Error("W-9 storage path is invalid.");
  const filename = `w9-v${data.version}.pdf`;

  const service = createServiceRoleClient();
  const { data: signed, error } = await service.storage.from(DRIVER_W9_BUCKET).createSignedUrl(expected, 300, download ? { download: filename } : undefined);
  if (error || !signed) throw new Error("Could not create a secure W-9 link.");
  return { url: signed.signedUrl, filename };
}
