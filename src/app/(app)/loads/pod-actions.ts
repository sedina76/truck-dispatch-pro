"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentOrgId } from "@/lib/actions/records";
import { syncExceptionsForDispatch } from "@/lib/exceptions/sync";
import { validateUploadedFile } from "@/lib/documents/validate-upload";
import { MAX_UPLOAD_BYTES, ALLOWED_UPLOAD_MIME_TYPES } from "@/lib/documents/upload-limits";
import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

// Phase 2E push-hook shared by upload/verify/reject below -- POD Missing's
// source identity is the LOAD (see sync.ts), but the sync entry point
// takes a dispatch id, so resolve the load's current dispatch (if any) and
// re-sync from there. Fire-and-forget + isolated: a failure here must
// never break the document upload/verify/reject action itself.
async function syncPodExceptionForLoad(organizationId: string, loadId: string) {
  const service = createServiceRoleClient();
  const { data: dispatch } = await service.from("dispatches").select("id").eq("load_id", loadId).order("dispatched_at", { ascending: false }).limit(1).maybeSingle();
  if (!dispatch) return;
  syncExceptionsForDispatch(service, organizationId, dispatch.id).catch((err) => console.warn("[pod-actions] exception sync failed:", err));
}

const ALLOWED_TYPES = new Set<string>(ALLOWED_UPLOAD_MIME_TYPES);
const MAX_BYTES = MAX_UPLOAD_BYTES;
const LOAD_DOCUMENT_TYPES = new Set([
  "pod",
  "rate_confirmation",
  "bol",
  "lumper_receipt",
  "detention_document",
  "scale_ticket",
  "other",
]);

export type UploadDocumentResult = { ok: true } | { ok: false; error: string };

// Returns a typed result rather than throwing -- same reasoning, and same
// established convention in this exact codebase, as generatePacket()
// (src/app/(app)/invoices/billing-packet-actions.ts): a Server Action's
// thrown error message is redacted to an opaque digest by Next.js in
// production by default, and a plain <form action={...}> additionally
// replaces the WHOLE page with Next's generic error boundary the instant
// anything throws -- confirmed live for this exact function during the
// prior investigation (a rejected fake PDF showed "Application error: a
// server-side exception has occurred", not the actual validation message).
// The caller (upload-document-form.tsx, a client component) reads this
// return value directly and renders the message inline instead.
//
// Staff upload path: uses the caller's own authenticated Supabase client
// (not a service-role bypass), so Storage RLS on the load-documents bucket
// (0023_pod_workflow.sql) applies exactly as it would to any other write --
// this can only ever write into the caller's own organization's folder,
// and only owner/admin/dispatcher per that policy. Shared by every
// load-linked document type (POD, rate confirmation, BOL, accessorials) --
// one upload path, not one per document type.
export async function uploadLoadDocument(loadId: string, documentType: string, formData: FormData): Promise<UploadDocumentResult> {
  if (!LOAD_DOCUMENT_TYPES.has(documentType)) return { ok: false, error: `Unsupported document type: ${documentType}` };
  const file = formData.get("file");
  if (!(file instanceof File)) return { ok: false, error: "No file provided." };
  if (file.size > MAX_BYTES) return { ok: false, error: "File is too large (15 MB max)." };
  if (!ALLOWED_TYPES.has(file.type)) return { ok: false, error: "Unsupported file type. Use PDF, JPG, or PNG." };
  // Real content check, not just the claimed MIME type (see
  // validate-upload.ts's own header comment for why this exists). Not
  // loosened by this change -- same validateUploadedFile() call, same
  // rules, only how the failure is REPORTED changed.
  const validation = await validateUploadedFile(file);
  if (!validation.ok) return { ok: false, error: validation.error };

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: load } = await supabase.from("loads").select("id").eq("id", loadId).single();
  if (!load) return { ok: false, error: "Load not found." };

  const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-100);
  const storagePath = `${organizationId}/${loadId}/${Date.now()}_${safeName}`;

  const { error: uploadError } = await supabase.storage
    .from("load-documents")
    .upload(storagePath, file, { contentType: file.type, upsert: false });
  if (uploadError) return { ok: false, error: uploadError.message };

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
  if (insertError) return { ok: false, error: insertError.message };

  await supabase.rpc("log_activity", { p_entity_type: "load", p_entity_id: loadId, p_action: `${documentType}_uploaded` });
  // Phase 2E push-hook -- a NEW pod document (upload or replacement) is
  // one of POD Missing's own meaningful transitions (spec review item 1).
  if (documentType === "pod") await syncPodExceptionForLoad(organizationId, loadId);
  revalidatePath(`/loads/${loadId}`);
  return { ok: true };
}

// Thin wrapper kept for the existing POD upload/replace forms.
export async function uploadPod(loadId: string, formData: FormData): Promise<UploadDocumentResult> {
  return uploadLoadDocument(loadId, "pod", formData);
}

export async function verifyPod(documentId: string, loadId: string) {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { error } = await supabase
    .from("documents")
    .update({ is_verified: true, verified_by: user?.id ?? null, verified_at: new Date().toISOString(), rejected_at: null, rejected_by: null, rejection_reason: null })
    .eq("id", documentId);
  if (error) throw new Error(error.message);

  // Phase 2E push-hook -- verification is POD Missing's other meaningful
  // transition (it can also RE-open a prior episode if this document was
  // previously the rejected one being superseded -- reconcile() handles
  // that the same as any other re-sync).
  await syncPodExceptionForLoad(organizationId, loadId);
  revalidatePath(`/loads/${loadId}`);
}

export async function rejectPod(documentId: string, loadId: string, formData: FormData) {
  const reason = String(formData.get("reason") || "").trim();
  if (!reason) throw new Error("A rejection reason is required.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
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

  // Phase 2E push-hook -- a rejection does NOT satisfy the POD requirement
  // (spec review item 2), so this can RE-OPEN POD Missing for the load if
  // this was the only/latest document on file.
  await syncPodExceptionForLoad(organizationId, loadId);
  revalidatePath(`/loads/${loadId}`);
}

// Bucket is private -- every view/download goes through a short-lived
// signed URL generated server-side, never a stored/logged permanent link.
// download=true asks Storage to set Content-Disposition: attachment so the
// browser saves the file instead of opening it inline.
//
// Phase 2G.8 finding: this function takes a raw storage path with no
// concept of document_type, org, or role -- Storage RLS
// (load_documents_select, 0023_pod_workflow.sql) only checks the path's
// org prefix, never document type or caller role. That's correct for
// POD (every role legitimately needs POD), but SimpleDocumentSlot
// (src/components/loads/simple-document-slot.tsx) also called this SAME
// function for the Rate Confirmation slot -- meaning even after Load
// Detail stopped rendering that slot for driver/viewer, a caller who
// still had (or guessed) the storage path could invoke this action
// directly and get a real signed URL to a Rate Confirmation, regardless
// of role. Hiding the button was never the boundary; this function itself
// never checked one. Left unchanged for POD/BOL/lumper/detention/scale-
// ticket (operational, not financial) -- see getFinancialDocumentSignedUrl
// below for the one document type (rate_confirmation) that needed its own
// gate.
export async function getPodSignedUrl(storagePath: string, download: boolean): Promise<string> {
  const supabase = await createClient();
  const { data, error } = await supabase.storage
    .from("load-documents")
    .createSignedUrl(storagePath, 300, download ? { download: true } : undefined);
  if (error || !data) throw new Error(error?.message ?? "Could not generate a document link.");
  return data.signedUrl;
}

// Guarded variant for financial documents (Rate Confirmation today). The
// role check happens BEFORE the signed URL is ever created -- an
// unauthorized caller gets a thrown error, no URL, nothing to leak,
// regardless of whether any page currently renders a button that could
// call this.
export async function getFinancialDocumentSignedUrl(storagePath: string, download: boolean): Promise<string> {
  await requireRole(FINANCIAL_ROLES);
  return getPodSignedUrl(storagePath, download);
}
