import "server-only";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { driverDocumentNotice } from "./document-notice";

type ServiceRoleClient = ReturnType<typeof createServiceRoleClient>;

/**
 * A driver uploaded a document from the Driver Portal: one bell
 * notification per active owner/admin/dispatcher/accountant (they verify
 * PODs and bill the load). The bell links to the load; the staff watcher
 * chimes for it. Best-effort: never fails the driver's upload.
 */
export async function notifyOfficeOfDriverDocument(
  supabase: ServiceRoleClient,
  p: { organizationId: string; loadId: string; documentType: string; driverName: string | null }
): Promise<void> {
  try {
    const [{ data: recipients }, { data: load }] = await Promise.all([
      supabase.from("profiles").select("id").eq("organization_id", p.organizationId).in("role", ["owner", "admin", "dispatcher", "accountant"]).eq("is_active", true),
      supabase.from("loads").select("load_number").eq("id", p.loadId).eq("organization_id", p.organizationId).maybeSingle(),
    ]);
    if (!recipients || recipients.length === 0) return;
    const { title, body } = driverDocumentNotice(p.documentType, load?.load_number ?? null, p.driverName);
    const rows = recipients.map((r) => ({
      organization_id: p.organizationId,
      profile_id: r.id,
      type: "system" as const,
      title,
      body,
      entity_type: "load" as const,
      entity_id: p.loadId,
    }));
    const { error } = await supabase.from("notifications").insert(rows);
    if (error) console.error("[driver-document] notification insert failed:", error);
  } catch (err) {
    console.error("[driver-document] notification failed:", err);
  }
}
