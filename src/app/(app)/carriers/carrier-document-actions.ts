"use server";

import { revalidatePath } from "next/cache";
import { requireOperationalAccess } from "@/lib/billing/operational-access";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { emptyToNull } from "@/lib/utils/form";
import { validateUploadedFile } from "@/lib/documents/validate-upload";
import { MAX_UPLOAD_BYTES, ALLOWED_UPLOAD_MIME_TYPES } from "@/lib/documents/upload-limits";
import { CARRIER_UPLOAD_DOCUMENT_TYPES } from "@/lib/documents/library";
import { OWNER_ADMIN_ROLES, type OrgRole } from "@/lib/auth/require-role";

// ---------------------------------------------------------------------------
// Real staff-facing carrier document upload -- mirrors uploadLoadDocument()
// (loads/pod-actions.ts) exactly, for entity_type='carrier'.
//
// STORAGE: reuses the existing private `load-documents` bucket (0023). Its
// RLS (load_documents_select/insert) is org-prefix + staff-role only --
// `(storage.foldername(name))[1] = current_org_id()::text` and
// has_role(['owner','admin','dispatcher']) -- with no load-specific logic;
// maintenance/actions.ts already reuses it the same way. No new bucket, no
// RLS change, no migration. Objects live at
//   {organization_id}/carrier/{carrier_id}/{ts}_{rand}_{safe_name}
// so the first path segment satisfies the bucket policy exactly.
//
// Returns {ok,error} for every expected failure (matching
// uploadLoadDocument()) so the client form can render it inline instead of
// tripping Next's generic error page.
// ---------------------------------------------------------------------------

const BUCKET = "load-documents";
const ALLOWED_TYPES = new Set<string>(CARRIER_UPLOAD_DOCUMENT_TYPES);

export type CarrierDocumentUploadResult = { ok: true } | { ok: false; error: string };

export async function uploadCarrierDocument(
  carrierId: string,
  documentType: string,
  formData: FormData
): Promise<CarrierDocumentUploadResult> {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  if (!ALLOWED_TYPES.has(documentType)) {
    return { ok: false, error: "That document type cannot be uploaded here." };
  }

  const file = formData.get("file");
  if (!(file instanceof File)) return { ok: false, error: "No file provided." };
  if (file.size === 0) return { ok: false, error: "The file is empty." };
  if (file.size > MAX_UPLOAD_BYTES) return { ok: false, error: "File is too large (15 MB max)." };
  if (!(ALLOWED_UPLOAD_MIME_TYPES as readonly string[]).includes(file.type)) {
    return { ok: false, error: "Unsupported file type. Use PDF, JPG, or PNG." };
  }
  // Real content-signature check -- never trusts the claimed MIME type.
  const validation = await validateUploadedFile(file);
  if (!validation.ok) return { ok: false, error: validation.error };

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // Tenant check. RLS already scopes this read to the caller's org; the
  // explicit organization_id filter is defense-in-depth. A forged foreign
  // carrier id resolves to nothing -> same generic message, no existence
  // leak. guard_document_carrier_link() (0095) re-enforces this at the DB
  // on the insert below regardless.
  const { data: carrier } = await supabase
    .from("carriers")
    .select("id")
    .eq("id", carrierId)
    .eq("organization_id", organizationId)
    .maybeSingle();
  if (!carrier) return { ok: false, error: "That carrier is not available." };

  const expiryDate = emptyToNull(formData.get("expiry_date"));

  // Verification: only owner/admin may mark a freshly-uploaded document
  // verified. Any other role's flag is ignored (the form doesn't render it
  // for them).
  let isVerified = false;
  if (formData.get("is_verified") === "on") {
    const { data: roleData } = await supabase.rpc("current_role");
    const role = roleData as OrgRole | null;
    isVerified = !!role && OWNER_ADMIN_ROLES.includes(role);
  }

  const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-100) || "document";
  const storagePath = `${organizationId}/carrier/${carrierId}/${Date.now()}_${Math.random()
    .toString(36)
    .slice(2, 10)}_${safeName}`;

  // 1. Upload bytes to private storage first.
  const { error: uploadError } = await supabase.storage
    .from(BUCKET)
    .upload(storagePath, file, { contentType: file.type, upsert: false });
  if (uploadError) return { ok: false, error: uploadError.message };

  // 2. Create the metadata row. If it fails, remove the object just
  //    uploaded so no orphan is left behind.
  const nowIso = new Date().toISOString();
  const { error: insertError } = await supabase.from("documents").insert({
    organization_id: organizationId,
    entity_type: "carrier",
    entity_id: carrierId,
    document_type: documentType,
    file_name: file.name,
    file_path: storagePath,
    storage_bucket: BUCKET,
    file_size_bytes: file.size,
    mime_type: file.type,
    uploaded_by: user?.id ?? null,
    expiry_date: expiryDate,
    is_verified: isVerified,
    verified_by: isVerified ? user?.id ?? null : null,
    verified_at: isVerified ? nowIso : null,
  });
  if (insertError) {
    await supabase.storage.from(BUCKET).remove([storagePath]);
    return { ok: false, error: insertError.message };
  }

  await supabase.rpc("log_activity", {
    p_entity_type: "carrier",
    p_entity_id: carrierId,
    p_action: `${documentType}_uploaded`,
  });

  revalidatePath(`/carriers/${carrierId}`);
  return { ok: true };
}

// Short-lived signed URL for a carrier document. The bucket is private;
// every view/download goes through this, never a stored link. RLS-scoped
// lookup confirms the row is this org's own carrier document before a URL
// is ever generated.
export async function getCarrierDocumentSignedUrl(documentId: string, download: boolean): Promise<string> {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  const { data: doc } = await supabase
    .from("documents")
    .select("file_path, storage_bucket, entity_type")
    .eq("id", documentId)
    .eq("organization_id", organizationId)
    .eq("entity_type", "carrier")
    .maybeSingle();
  if (!doc) throw new Error("Document not available.");

  const { data, error } = await supabase.storage
    .from(doc.storage_bucket ?? BUCKET)
    .createSignedUrl(doc.file_path, 300, download ? { download: true } : undefined);
  if (error || !data) throw new Error(error?.message ?? "Could not generate a document link.");
  return data.signedUrl;
}

// Delete a carrier document uploaded through this workflow. Protected
// classes (signed_agreement, w9) and anything a dedicated workflow
// references are refused -- those are never created here anyway, but the
// guard is explicit. Removes the storage object after the row so nothing
// is orphaned.
export async function deleteCarrierDocument(documentId: string, carrierId: string): Promise<void> {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  const { data: doc } = await supabase
    .from("documents")
    .select("id, file_path, storage_bucket, entity_type, document_type")
    .eq("id", documentId)
    .eq("organization_id", organizationId)
    .eq("entity_type", "carrier")
    .maybeSingle();
  if (!doc) throw new Error("Document not available.");
  if (doc.document_type === "signed_agreement" || doc.document_type === "w9") {
    throw new Error("This document is protected and cannot be deleted here.");
  }

  const [{ data: w9Ref }, { data: policyRef }] = await Promise.all([
    supabase.from("carrier_w9s").select("id").eq("registered_document_id", documentId).maybeSingle(),
    supabase.from("insurance_policies").select("id").eq("document_id", documentId).maybeSingle(),
  ]);
  if (w9Ref || policyRef) {
    throw new Error("This document is linked to a compliance record and cannot be deleted here.");
  }

  const { error } = await supabase.from("documents").delete().eq("id", documentId);
  if (error) throw new Error(error.message);

  await supabase.storage.from(doc.storage_bucket ?? BUCKET).remove([doc.file_path]);

  revalidatePath(`/carriers/${carrierId}`);
}
