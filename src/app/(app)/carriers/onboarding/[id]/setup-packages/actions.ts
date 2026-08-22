"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentOrgId } from "@/lib/actions/records";
import { resolveEmailAuthorizationContext } from "@/lib/email/authorization";
import { sendTenantEmail } from "@/lib/email/send-pipeline";
import { SetupPackageResourceNotFoundError } from "@/lib/carrier-setup-packages/errors";
import { carrierSetupPackageFilename } from "@/lib/carrier-setup-packages/filename";
import { getSetupPackageSignedUrlOrThrow } from "@/lib/carrier-setup-packages/signed-url";
import { runBoundedStorageUpload, storageUploadErrorStatus, type StorageObjectConfirmation, type StorageUploadErrorLike } from "@/lib/carrier-setup-packages/storage-retry";
import { renderCarrierSetupPackage } from "@/lib/carrier-setup-packages/generate";
import {
  MAX_EMAIL_ATTACHMENT_BYTES,
  MAX_SOURCE_BYTES,
  SETUP_PACKAGE_BUCKET,
  setupPackageStoragePath,
  type SetupPackageItemRow,
  type SetupPackageRow,
} from "@/lib/carrier-setup-packages/types";

type GenerateSelection = { brokerId: string | null; recipientName: string; recipientEmail: string; documentIds: string[] };
type ActionResult<T = undefined> = T extends undefined ? { ok: true } | { ok: false; error: string } : { ok: true; data: T } | { ok: false; error: string };

async function authenticatedContext(allowed: string[]) {
  const supabase = await createClient();
  const [{ data: { user } }, { data: role }] = await Promise.all([supabase.auth.getUser(), supabase.rpc("current_role")]);
  if (!user) throw new Error("Not authenticated.");
  if (!allowed.includes(String(role))) throw new Error("You do not have permission to perform this action.");
  return { supabase, user, organizationId: await getCurrentOrgId() };
}

function safeFailureStage(message: string) {
  if (/download|source|document/i.test(message)) return "Package generation failed during source validation.";
  if (/pdf|page|image|merge/i.test(message)) return "Package generation failed during PDF composition.";
  if (/upload|storage/i.test(message)) return "Package generation failed during secure storage.";
  return "Package generation failed.";
}

const STORAGE_UPLOAD_RETRY_DELAY_MS = 250;

function logStorageUploadError(params: {
  error: StorageUploadErrorLike;
  attempt: number;
  packageId: string;
  organizationId: string;
  applicationId: string;
  packageVersion: number;
  generatedByteLength: number;
  objectPath: string;
}) {
  console.error("[carrier-setup-package-upload]", {
    operation: "carrier_setup_package_upload",
    attempt: params.attempt,
    packageId: params.packageId,
    organizationId: params.organizationId,
    applicationId: params.applicationId,
    packageVersion: params.packageVersion,
    generatedByteLength: params.generatedByteLength,
    bucket: SETUP_PACKAGE_BUCKET,
    objectPath: params.objectPath,
    errorName: params.error.name ?? null,
    errorMessage: params.error.message ?? null,
    status: storageUploadErrorStatus(params.error),
    statusCode: params.error.statusCode ?? null,
    code: params.error.code ?? null,
  });
}

async function confirmGeneratedObject(
  service: ReturnType<typeof createServiceRoleClient>,
  objectPath: string,
  expectedBytes: number
): Promise<"matching" | "absent" | "mismatch" | "unknown"> {
  const slash = objectPath.lastIndexOf("/");
  const folder = objectPath.slice(0, slash);
  const filename = objectPath.slice(slash + 1);
  const { data, error } = await service.storage.from(SETUP_PACKAGE_BUCKET).list(folder, { limit: 10, search: filename });
  if (error) return "unknown";
  const object = data?.find((entry) => entry.name === filename);
  if (!object) return "absent";
  const size = Number(object.metadata?.size);
  return Number.isFinite(size) && size === expectedBytes ? "matching" : "mismatch";
}

async function uploadGeneratedPackage(params: {
  service: ReturnType<typeof createServiceRoleClient>;
  objectPath: string;
  bytes: Uint8Array;
  packageId: string;
  organizationId: string;
  applicationId: string;
  packageVersion: number;
}): Promise<boolean> {
  const result = await runBoundedStorageUpload({
    upload: async () => {
      const { error } = await params.service.storage.from(SETUP_PACKAGE_BUCKET).upload(params.objectPath, params.bytes, {
        contentType: "application/pdf",
        upsert: false,
      });
      return error as (typeof error & StorageUploadErrorLike) | null;
    },
    confirmObject: () => confirmGeneratedObject(params.service, params.objectPath, params.bytes.length) as Promise<StorageObjectConfirmation>,
    delay: () => new Promise((resolve) => setTimeout(resolve, STORAGE_UPLOAD_RETRY_DELAY_MS)),
    onAttemptError: (error, attempt) => logStorageUploadError({ ...params, error, attempt, generatedByteLength: params.bytes.length }),
    onRetrySucceeded: () => console.info("[carrier-setup-package-upload]", { operation: "carrier_setup_package_upload_retry_succeeded", packageId: params.packageId, packageVersion: params.packageVersion }),
    onConfirmedAfterResponseFailure: (attempt) => console.info("[carrier-setup-package-upload]", { operation: "carrier_setup_package_upload_confirmed_after_response_failure", packageId: params.packageId, packageVersion: params.packageVersion, attempt }),
  });
  return result.ok;
}

export async function generateSetupPackage(applicationId: string, selection: GenerateSelection): Promise<ActionResult<{ packageId: string }>> {
  let packageId: string | null = null;
  let storagePath: string | null = null;
  try {
    const { supabase, organizationId } = await authenticatedContext(["owner", "admin", "dispatcher"]);
    const { data: reservation, error: reserveError } = await supabase.rpc("reserve_carrier_setup_package", {
      p_application_id: applicationId,
      p_broker_id: selection.brokerId || null,
      p_recipient_name: selection.recipientName || null,
      p_recipient_email: selection.recipientEmail || null,
      p_document_ids: selection.documentIds,
    });
    if (reserveError) return { ok: false, error: reserveError.message };
    const reserved = (reservation as { package_id: string; package_version: number }[] | null)?.[0];
    if (!reserved) return { ok: false, error: "Could not reserve a setup package version." };
    packageId = reserved.package_id;

    const [{ data: packageData }, { data: itemData }] = await Promise.all([
      supabase.from("carrier_setup_packages").select("*").eq("id", packageId).single(),
      supabase.from("carrier_setup_package_items").select("*").eq("package_id", packageId).order("display_order"),
    ]);
    if (!packageData || !itemData?.length) throw new Error("Reserved package data could not be read.");
    const pkg = packageData as unknown as SetupPackageRow;
    const items = itemData as unknown as SetupPackageItemRow[];
    if (pkg.organization_id !== organizationId || pkg.onboarding_application_id !== applicationId) throw new Error("Reserved package ownership is invalid.");

    const service = createServiceRoleClient();
    let totalBytes = 0;
    const sources = [];
    for (const item of items) {
      if (item.source_storage_bucket !== "carrier-onboarding-documents") throw new Error("A source document has an invalid storage location.");
      if (!item.source_storage_path.startsWith(`${organizationId}/${applicationId}/`)) throw new Error("A source document path is invalid.");
      const { data, error } = await service.storage.from(item.source_storage_bucket).download(item.source_storage_path);
      if (error || !data) throw new Error("A selected source document could not be downloaded.");
      const bytes = new Uint8Array(await data.arrayBuffer());
      if (item.source_file_size_bytes !== bytes.length) throw new Error("A source document changed after package reservation.");
      totalBytes += bytes.length;
      if (totalBytes > MAX_SOURCE_BYTES) throw new Error("Selected source documents exceed the 40 MB limit.");
      sources.push({ item, bytes });
    }

    const generated = await renderCarrierSetupPackage({
      version: pkg.version,
      preparedAt: new Date(),
      preparedForName: pkg.prepared_for_name,
      recipientName: pkg.recipient_name,
      recipientEmail: pkg.recipient_email,
      carrier: pkg.carrier_snapshot,
      organization: pkg.organization_snapshot,
      equipment: pkg.equipment_snapshot,
      sources,
    });
    storagePath = setupPackageStoragePath(pkg);
    const uploaded = await uploadGeneratedPackage({ service, objectPath: storagePath, bytes: generated.bytes, packageId: pkg.id, organizationId, applicationId, packageVersion: pkg.version });
    if (!uploaded) throw new Error("The generated package could not be uploaded to secure storage.");

    const { error: finalizeError } = await service.rpc("finalize_carrier_setup_package", {
      p_package_id: packageId,
      p_storage_path: storagePath,
      p_file_size_bytes: generated.bytes.length,
      p_page_count: generated.pageCount,
      p_item_results: generated.itemResults,
    });
    if (finalizeError) throw new Error("The generated package could not be finalized.");
    await supabase.rpc("log_activity", { p_entity_type: "carrier_onboarding_application", p_entity_id: applicationId, p_action: "carrier_setup_package_generated", p_changes: { package_id: packageId, version: pkg.version, document_count: items.length } });
    revalidatePath(`/carriers/onboarding/${applicationId}`);
    revalidatePath(`/carriers/onboarding/${applicationId}/setup-packages/${packageId}`);
    return { ok: true, data: { packageId } };
  } catch (error) {
    const message = error instanceof Error ? error.message : "Package generation failed.";
    if (packageId) {
      const service = createServiceRoleClient();
      if (storagePath) await service.storage.from(SETUP_PACKAGE_BUCKET).remove([storagePath]);
      await service.rpc("fail_carrier_setup_package", { p_package_id: packageId, p_failure_reason: safeFailureStage(message) });
    }
    return { ok: false, error: message };
  }
}

export async function getSetupPackageSignedUrl(
  packageId: string,
  download: boolean
): Promise<ActionResult<{ url: string; filename: string }>> {
  try {
    return { ok: true, data: await getSetupPackageSignedUrlOrThrow(packageId, download) };
  } catch (error) {
    if (error instanceof SetupPackageResourceNotFoundError) {
      return { ok: false, error: "Package not found." };
    }
    throw error;
  }
}

export async function sendSetupPackage(packageId: string, input: { recipientName: string; to: string; subject: string; message: string; explicitResend: boolean }): Promise<ActionResult> {
  try {
    const { supabase, user, organizationId } = await authenticatedContext(["owner", "admin", "dispatcher"]);
    const { data } = await supabase.from("carrier_setup_packages").select("*").eq("id", packageId).maybeSingle();
    if (!data || data.organization_id !== organizationId || !["generated", "sent"].includes(data.status)) return { ok: false, error: "Generated package not found." };
    const pkg = data as unknown as SetupPackageRow;
    if (!pkg.generated_storage_path || !pkg.generated_file_size_bytes) return { ok: false, error: "This package has no generated PDF." };
    if (pkg.generated_file_size_bytes > MAX_EMAIL_ATTACHMENT_BYTES) return { ok: false, error: "Package is too large to email. Download the PDF and send it using your preferred delivery method." };
    const expected = setupPackageStoragePath(pkg);
    if (pkg.generated_storage_path !== expected) return { ok: false, error: "Package storage path is invalid." };
    const service = createServiceRoleClient();
    const { data: file, error: fileError } = await service.storage.from(SETUP_PACKAGE_BUCKET).download(expected);
    if (fileError || !file) return { ok: false, error: "Could not read the immutable package PDF." };
    const attachmentBytes = Buffer.from(await file.arrayBuffer());
    if (attachmentBytes.length !== pkg.generated_file_size_bytes) return { ok: false, error: "The stored package no longer matches its immutable metadata." };
    if (attachmentBytes.length > MAX_EMAIL_ATTACHMENT_BYTES) return { ok: false, error: "Package is too large to email. Download the PDF and send it using your preferred delivery method." };
    const auth = await resolveEmailAuthorizationContext();
    if (!auth.ok) return { ok: false, error: auth.error };
    const result = await sendTenantEmail({
      authContext: auth.context,
      emailPurpose: "carrier_setup_package",
      to: [input.to],
      subject: input.subject,
      text: input.message,
      attachments: [{ filename: carrierSetupPackageFilename(pkg.carrier_snapshot.legal_name, new Date().toISOString().slice(0, 10), pkg.version), content: attachmentBytes }],
      entityType: "carrier_setup_package",
      entityId: pkg.id,
      entities: { brokerId: pkg.broker_id, carrierSetupPackageId: pkg.id },
      sentBy: user.id,
      idempotencyBaseKey: `carrier_setup_package_sent:${pkg.id}`,
      isExplicitResend: input.explicitResend,
      metadata: { package_version: pkg.version, document_count: pkg.document_count, recipient_name: input.recipientName || null },
    });
    if (!result.ok) return { ok: false, error: result.error };
    const { error: markError } = await supabase.rpc("mark_carrier_setup_package_sent", { p_package_id: pkg.id, p_email_send_log_id: result.emailSendLogId });
    if (markError) return { ok: false, error: "Email sent, but package history could not be updated. Review Email History before retrying." };
    await supabase.rpc("log_activity", { p_entity_type: "carrier_onboarding_application", p_entity_id: pkg.onboarding_application_id, p_action: "carrier_setup_package_sent", p_changes: { package_id: pkg.id, version: pkg.version, broker_id: pkg.broker_id } });
    revalidatePath(`/carriers/onboarding/${pkg.onboarding_application_id}`);
    revalidatePath(`/carriers/onboarding/${pkg.onboarding_application_id}/setup-packages/${pkg.id}`);
    return { ok: true };
  } catch (error) { return { ok: false, error: error instanceof Error ? error.message : "Could not send the setup package." }; }
}

export async function voidSetupPackage(packageId: string, reason: string): Promise<ActionResult> {
  try {
    const { supabase } = await authenticatedContext(["owner", "admin"]);
    const { data: pkg } = await supabase.from("carrier_setup_packages").select("onboarding_application_id").eq("id", packageId).maybeSingle();
    if (!pkg) return { ok: false, error: "Package not found." };
    const { error } = await supabase.rpc("void_carrier_setup_package", { p_package_id: packageId, p_reason: reason });
    if (error) return { ok: false, error: error.message };
    await supabase.rpc("log_activity", { p_entity_type: "carrier_onboarding_application", p_entity_id: pkg.onboarding_application_id, p_action: "carrier_setup_package_voided", p_changes: { package_id: packageId } });
    revalidatePath(`/carriers/onboarding/${pkg.onboarding_application_id}`);
    revalidatePath(`/carriers/onboarding/${pkg.onboarding_application_id}/setup-packages/${packageId}`);
    return { ok: true };
  } catch (error) { return { ok: false, error: error instanceof Error ? error.message : "Could not void the package." }; }
}
