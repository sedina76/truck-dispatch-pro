import { NextRequest, NextResponse } from "next/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { validateUploadedFile } from "@/lib/documents/validate-upload";
import { getDriverOnboardingSession } from "@/lib/driver-onboarding/session";

const MAX_BYTES = 10 * 1024 * 1024; // matches the bucket's file_size_limit
const ALLOWED_TYPES = new Set(["application/pdf", "image/jpeg", "image/png", "image/heic"]);

// Shared by two callers with two different trust models (Phase 2Q.2):
//   1. The public, anonymous /driver-application form -- no Supabase Auth
//      session at all, so there's no caller identity to verify beyond the
//      client-generated draft id itself. Unchanged: still an acceptable
//      trust boundary for a public job-application form with nothing
//      sensitive being *read*.
//   2. The carrier-invited /driver-onboarding portal (2Q.2) -- THIS caller
//      DOES have a real, session-cookie-backed identity. When that cookie
//      is present, application_id is no longer taken on faith: it must
//      match the session's own applicationId, exactly like every other
//      driver-onboarding action in this phase (never trust an entity id
//      supplied only by the browser once a stronger signal exists).
// Either way, validateUploadedFile() now real-checks the file's magic
// bytes before it's ever written to storage -- this route previously
// trusted the browser-reported MIME type alone, unlike every other upload
// path in this codebase (src/lib/documents/validate-upload.ts). A real
// PDF/JPEG/PNG/HEIC file is unaffected; only a mislabeled/fake file is
// newly rejected.
export async function POST(request: NextRequest) {
  const formData = await request.formData();
  const file = formData.get("file");
  const applicationId = String(formData.get("application_id") || "");
  const label = String(formData.get("label") || "document");

  if (!(file instanceof File)) {
    return NextResponse.json({ error: "No file provided." }, { status: 400 });
  }
  if (!/^[0-9a-f-]{36}$/i.test(applicationId)) {
    return NextResponse.json({ error: "Invalid application id." }, { status: 400 });
  }
  if (file.size > MAX_BYTES) {
    return NextResponse.json({ error: "File is too large (10 MB max)." }, { status: 400 });
  }
  if (!ALLOWED_TYPES.has(file.type)) {
    return NextResponse.json({ error: "Unsupported file type. Use PDF, JPEG, PNG, or HEIC." }, { status: 400 });
  }

  const session = await getDriverOnboardingSession();
  if (session && session.applicationId !== applicationId) {
    return NextResponse.json({ error: "This application is not part of your onboarding session." }, { status: 403 });
  }

  const validation = await validateUploadedFile(file);
  if (!validation.ok) return NextResponse.json({ error: validation.error }, { status: 400 });

  const supabase = createServiceRoleClient();
  const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-100);
  const storagePath = `${applicationId}/${Date.now()}_${safeName}`;

  const { error } = await supabase.storage
    .from("driver-application-documents")
    .upload(storagePath, await file.arrayBuffer(), { contentType: file.type, upsert: false });

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }

  return NextResponse.json({
    ok: true,
    document: { label, storage_path: storagePath, file_name: file.name, uploaded_at: new Date().toISOString() },
  });
}
