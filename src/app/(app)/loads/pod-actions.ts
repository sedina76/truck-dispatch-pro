"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";

const ALLOWED_TYPES = new Set(["application/pdf", "image/jpeg", "image/png"]);
const MAX_BYTES = 15 * 1024 * 1024;
const LOAD_DOCUMENT_TYPES = new Set([
  "pod",
  "rate_confirmation",
  "bol",
  "lumper_receipt",
  "detention_document",
  "scale_ticket",
  "other",
]);

// Staff upload path: uses the caller's own authenticated Supabase client
// (not a service-role bypass), so Storage RLS on the load-documents bucket
// (0023_pod_workflow.sql) applies exactly as it would to any other write --
// this can only ever write into the caller's own organization's folder,
// and only owner/admin/dispatcher per that policy. Shared by every
// load-linked document type (POD, rate confirmation, BOL, accessorials) --
// one upload path, not one per document type.
export async function uploadLoadDocument(loadId: string, documentType: string, formData: FormData) {
  if (!LOAD_DOCUMENT_TYPES.has(documentType)) throw new Error(`Unsupported document type: ${documentType}`);
  const file = formData.get("file");
  if (!(file instanceof File)) throw new Error("No file provided.");
  if (file.size > MAX_BYTES) throw new Error("File is too large (15 MB max).");
  if (!ALLOWED_TYPES.has(file.type)) throw new Error("Unsupported file type. Use PDF, JPG, or PNG.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: load } = await supabase.from("loads").select("id").eq("id", loadId).single();
  if (!load) throw new Error("Load not found.");

  const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-100);
  const storagePath = `${organizationId}/${loadId}/${Date.now()}_${safeName}`;

  const { error: uploadError } = await supabase.storage
    .from("load-documents")
    .upload(storagePath, file, { contentType: file.type, upsert: false });
  if (uploadError) throw new Error(uploadError.message);

  const { error: insertError } = await supabase.from("documents").insert({
    organization_id: organizationId,
    entity_type: "load",
    entity_id: loadId,
    document_type: documentType,
    file_name: file.name,
    file_path: storagePath,
    file_size_bytes: file.size,
    mime_type: file.type,
    uploaded_by: user?.id ?? null,
  });
  if (insertError) throw new Error(insertError.message);

  await supabase.rpc("log_activity", { p_entity_type: "load", p_entity_id: loadId, p_action: `${documentType}_uploaded` });
  revalidatePath(`/loads/${loadId}`);
}

// Thin wrapper kept for the existing POD upload/replace forms.
export async function uploadPod(loadId: string, formData: FormData) {
  return uploadLoadDocument(loadId, "pod", formData);
}

export async function verifyPod(documentId: string, loadId: string) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { error } = await supabase
    .from("documents")
    .update({ is_verified: true, verified_by: user?.id ?? null, verified_at: new Date().toISOString(), rejected_at: null, rejected_by: null, rejection_reason: null })
    .eq("id", documentId);
  if (error) throw new Error(error.message);

  revalidatePath(`/loads/${loadId}`);
}

export async function rejectPod(documentId: string, loadId: string, formData: FormData) {
  const reason = String(formData.get("reason") || "").trim();
  if (!reason) throw new Error("A rejection reason is required.");

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { error } = await supabase
    .from("documents")
    .update({
      is_verified: false,
      rejected_at: new Date().toISOString(),
      rejected_by: user?.id ?? null,
      rejection_reason: reason,
    })
    .eq("id", documentId);
  if (error) throw new Error(error.message);

  revalidatePath(`/loads/${loadId}`);
}

// Bucket is private -- every view/download goes through a short-lived
// signed URL generated server-side, never a stored/logged permanent link.
// download=true asks Storage to set Content-Disposition: attachment so the
// browser saves the file instead of opening it inline.
export async function getPodSignedUrl(storagePath: string, download: boolean): Promise<string> {
  const supabase = await createClient();
  const { data, error } = await supabase.storage
    .from("load-documents")
    .createSignedUrl(storagePath, 300, download ? { download: true } : undefined);
  if (error || !data) throw new Error(error?.message ?? "Could not generate a document link.");
  return data.signedUrl;
}
