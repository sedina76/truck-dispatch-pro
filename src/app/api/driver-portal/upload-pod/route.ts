import { NextRequest, NextResponse } from "next/server";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { syncExceptionsForDispatch } from "@/lib/exceptions/sync";
import { validateUploadedFile } from "@/lib/documents/validate-upload";

const ALLOWED_TYPES = new Set(["application/pdf", "image/jpeg", "image/png"]);
const MAX_BYTES = 15 * 1024 * 1024;

// Driver portal has no Supabase Auth session, so this goes through the same
// pattern as /api/driver-portal/location: verify the custom session cookie
// server-side, then use the service_role key (bypasses Storage/table RLS)
// -- but only after independently confirming the load actually belongs to
// THIS driver's own dispatch. That check is the real access control here,
// not the bucket policy (which has no anon/authenticated grant at all for
// this path -- see 0023_pod_workflow.sql).
export async function POST(request: NextRequest) {
  const identity = await getDriverPortalSession();
  if (!identity) {
    return NextResponse.json({ error: "Not signed in." }, { status: 401 });
  }

  const formData = await request.formData();
  const file = formData.get("file");
  const loadId = String(formData.get("load_id") || "");

  if (!(file instanceof File)) {
    return NextResponse.json({ error: "No file provided." }, { status: 400 });
  }
  if (!/^[0-9a-f-]{36}$/i.test(loadId)) {
    return NextResponse.json({ error: "Invalid load id." }, { status: 400 });
  }
  if (file.size > MAX_BYTES) {
    return NextResponse.json({ error: "File is too large (15 MB max)." }, { status: 400 });
  }
  if (!ALLOWED_TYPES.has(file.type)) {
    return NextResponse.json({ error: "Unsupported file type. Use PDF, JPG, or PNG." }, { status: 400 });
  }
  // Real content check, not just the claimed MIME type (see
  // validate-upload.ts's own header comment for why this exists).
  const validation = await validateUploadedFile(file);
  if (!validation.ok) {
    return NextResponse.json({ error: validation.error }, { status: 400 });
  }

  const supabase = createServiceRoleClient();

  // The one real authorization check: this load must be on a dispatch
  // actually assigned to this driver. Never trusts the client-supplied
  // driver identity -- identity.driverId comes from the verified session.
  const { data: dispatch } = await supabase
    .from("dispatches")
    .select("id")
    .eq("load_id", loadId)
    .eq("driver_id", identity.driverId)
    .maybeSingle();
  if (!dispatch) {
    return NextResponse.json({ error: "This load is not assigned to you." }, { status: 403 });
  }

  const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-100);
  const storagePath = `${identity.organizationId}/${loadId}/${Date.now()}_${safeName}`;

  const { error: uploadError } = await supabase.storage
    .from("load-documents")
    .upload(storagePath, await file.arrayBuffer(), { contentType: file.type, upsert: false });
  if (uploadError) {
    return NextResponse.json({ error: uploadError.message }, { status: 500 });
  }

  const { error: insertError } = await supabase.from("documents").insert({
    organization_id: identity.organizationId,
    entity_type: "load",
    entity_id: loadId,
    document_type: "pod",
    file_name: file.name,
    file_path: storagePath,
    file_size_bytes: file.size,
    mime_type: file.type,
    // uploaded_by references profiles(id) -- drivers aren't Supabase Auth
    // users and have no profiles row, so this is left null. The document
    // is still fully attributed via the driver_id already implied by the
    // load/dispatch relationship this route just verified.
    uploaded_by: null,
  });
  if (insertError) {
    return NextResponse.json({ error: insertError.message }, { status: 500 });
  }

  // Phase 2E push-hook -- the driver's own upload is a meaningful POD
  // Missing transition too, same as the staff-side upload path. Isolated:
  // must never fail the driver's own upload response.
  syncExceptionsForDispatch(supabase, identity.organizationId, dispatch.id).catch((err) => console.warn("[driver-portal upload-pod] exception sync failed:", err));

  return NextResponse.json({ ok: true });
}
