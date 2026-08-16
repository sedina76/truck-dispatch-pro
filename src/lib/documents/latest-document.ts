// The one shared "what's the current document of this type for this load"
// query, used everywhere a document's latest state matters: POD status
// (load page, invoice page, driver trip history, dashboard alert), and now
// rate confirmation / BOL / accessorials on the billing packet. Always
// "most recent row wins" -- never an older verified/on-file row, even if a
// newer upload for the same type exists and is itself unverified/rejected.
// This is the exact rule the POD workflow already established; every
// caller MUST go through this function rather than writing its own
// order-by-created-at-desc-limit-1 query, which is how the dashboard/POD
// inconsistency bug happened before.

export type DocumentRow = {
  id: string;
  document_type: string;
  file_name: string;
  file_path: string;
  mime_type: string | null;
  created_at: string;
  uploaded_by: string | null;
  is_verified: boolean;
  verified_by: string | null;
  verified_at: string | null;
  rejected_at: string | null;
  rejected_by: string | null;
  rejection_reason: string | null;
};

const DOCUMENT_SELECT =
  "id, document_type, file_name, file_path, mime_type, created_at, uploaded_by, is_verified, verified_by, verified_at, rejected_at, rejected_by, rejection_reason";

// Untyped client param, deliberately: this project's Supabase client isn't
// parameterized with generated types yet (see src/types/supabase.ts), so
// every query builder call already falls back to loosely-typed results
// throughout this codebase. Accepting the real client type here would fight
// that rather than fix it -- callers already cast query results themselves.
export async function getLatestDocument(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  supabase: any,
  entityType: string,
  entityId: string,
  documentType: string
): Promise<DocumentRow | null> {
  const { data } = await supabase
    .from("documents")
    .select(DOCUMENT_SELECT)
    .eq("entity_type", entityType)
    .eq("entity_id", entityId)
    .eq("document_type", documentType)
    .order("created_at", { ascending: false })
    .limit(1);
  return data?.[0] ?? null;
}

// Batch form for list pages (dashboard, loads list, driver trip history)
// that need this for many entities at once without N+1 queries. Returns the
// latest row per entity_id. entityIds is optional -- omit it (e.g. the
// dashboard's org-wide "delivered loads missing POD" count, which doesn't
// know which load ids matter until after this resolves) to scan every
// document of that type in the org rather than a specific id list.
export async function getLatestDocumentsByEntity(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  supabase: any,
  entityType: string,
  documentType: string,
  entityIds?: string[]
): Promise<Map<string, DocumentRow>> {
  const result = new Map<string, DocumentRow>();
  if (entityIds && entityIds.length === 0) return result;

  let query = supabase
    .from("documents")
    .select(`entity_id, ${DOCUMENT_SELECT}`)
    .eq("entity_type", entityType)
    .eq("document_type", documentType);
  if (entityIds) query = query.in("entity_id", entityIds);
  const { data } = await query.order("created_at", { ascending: false });

  for (const row of data ?? []) {
    if (!result.has(row.entity_id)) result.set(row.entity_id, row);
  }
  return result;
}
