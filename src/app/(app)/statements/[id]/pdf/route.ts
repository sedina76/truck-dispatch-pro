import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { requireRoleForApi, FINANCIAL_ROLES } from "@/lib/auth/require-role";

// Print/Export target for a generated statement. The stored PDF lives in a
// PRIVATE Supabase Storage bucket (0029_statements.sql) -- there is no
// permanent public URL for it and there never should be. This route
// resolves a fresh, short-lived (300s) signed URL server-side, scoped by
// the same RLS the statement row itself is under (an org-B caller simply
// gets 404 here -- the row is invisible), and redirects to it. Toolbar
// Print/Export both point here rather than a static href, so the link
// never goes stale even if the user waits a while before clicking.
export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const denied = await requireRoleForApi(FINANCIAL_ROLES);
  if (denied) return denied;

  const { id } = await params;
  const { searchParams } = new URL(req.url);
  const download = searchParams.get("download") === "1";

  const supabase = await createClient();
  const { data: statement } = await supabase.from("statements").select("storage_path").eq("id", id).maybeSingle();
  if (!statement?.storage_path) {
    return new Response("Statement PDF not found.", { status: 404 });
  }

  const { data, error } = await supabase.storage
    .from("statements")
    .createSignedUrl(statement.storage_path, 300, download ? { download: true } : undefined);
  if (error || !data) {
    return new Response("Could not generate a download link.", { status: 500 });
  }

  redirect(data.signedUrl);
}
