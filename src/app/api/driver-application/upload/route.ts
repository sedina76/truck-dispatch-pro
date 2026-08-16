import { NextRequest, NextResponse } from "next/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";

const MAX_BYTES = 10 * 1024 * 1024; // matches the bucket's file_size_limit
const ALLOWED_TYPES = new Set(["application/pdf", "image/jpeg", "image/png", "image/heic"]);

// The applicant has no Supabase Auth session, so this can't go through a
// normal authenticated Storage upload -- it uses the service_role key to
// write into the private driver-application-documents bucket. There's no
// caller identity to verify here (unlike the driver-portal route handlers)
// because nothing sensitive is being *read*; a write-only, size/type-limited
// upload endpoint keyed by a client-generated draft id is an acceptable
// trust boundary for a public job-application form.
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
