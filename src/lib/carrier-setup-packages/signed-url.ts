import "server-only";

import { getCurrentOrgId } from "@/lib/actions/records";
import { createClient } from "@/lib/supabase/server";
import { SetupPackageResourceNotFoundError } from "./errors";
import { carrierSetupPackageFilename } from "./filename";
import { SETUP_PACKAGE_BUCKET } from "./types";

const DOWNLOAD_ROLES = new Set(["owner", "admin", "dispatcher", "accountant"]);

export async function getSetupPackageSignedUrlOrThrow(
  packageId: string,
  download: boolean
): Promise<{ url: string; filename: string }> {
  const supabase = await createClient();
  const [{ data: { user } }, { data: role }] = await Promise.all([
    supabase.auth.getUser(),
    supabase.rpc("current_role"),
  ]);
  if (!user || !DOWNLOAD_ROLES.has(String(role))) {
    throw new SetupPackageResourceNotFoundError();
  }

  const organizationId = await getCurrentOrgId();
  const { data } = await supabase
    .from("carrier_setup_packages")
    .select("id, organization_id, onboarding_application_id, version, status, generated_storage_path, generated_at, carrier_snapshot")
    .eq("id", packageId)
    .maybeSingle();
  if (!data || data.organization_id !== organizationId || !["generated", "sent"].includes(data.status) || !data.generated_storage_path) {
    throw new SetupPackageResourceNotFoundError();
  }

  const expected = `${organizationId}/${data.onboarding_application_id}/${data.id}/carrier-setup-package-v${data.version}.pdf`;
  if (data.generated_storage_path !== expected) throw new Error("Package storage path is invalid.");
  const snapshot = data.carrier_snapshot as unknown as { legal_name?: string };
  const filename = carrierSetupPackageFilename(snapshot.legal_name ?? "Carrier", (data.generated_at ?? new Date().toISOString()).slice(0, 10), data.version);
  const { data: signed, error } = await supabase.storage
    .from(SETUP_PACKAGE_BUCKET)
    .createSignedUrl(expected, 300, download ? { download: filename } : undefined);
  if (error || !signed) throw new Error("Could not create a secure package link.");
  return { url: signed.signedUrl, filename };
}
