import "server-only";
import { createClient } from "@/lib/supabase/server";

// Tolerant, tenant-scoped reads for the QuickBooks mapping/sync UI. RLS
// (owner/admin + current_org_id) scopes every query. If migration 0117 is
// not applied yet, the tables do not exist -- every helper returns "not
// mapped / not synced" rather than throwing, so the pages render fine.

export type EntityMappingView = { displayName: string | null } | null;

export async function getEntityQuickbooksMapping(
  entityType: "customer" | "broker",
  entityId: string
): Promise<EntityMappingView> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("quickbooks_customer_mappings")
    .select("quickbooks_display_name")
    .eq("local_entity_type", entityType)
    .eq("local_entity_id", entityId)
    .maybeSingle();
  if (error || !data) return null;
  return { displayName: (data.quickbooks_display_name as string | null) ?? null };
}

export type InvoiceSyncRead = {
  status: "pending" | "synced" | "failed";
  docNumber: string | null;
  syncedAt: string | null;
  lastErrorMessage: string | null;
} | null;

export async function getInvoiceQuickbooksSync(invoiceId: string): Promise<InvoiceSyncRead> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("quickbooks_invoice_syncs")
    .select("sync_status, quickbooks_doc_number, last_synced_at, last_error_message")
    .eq("invoice_id", invoiceId)
    .maybeSingle();
  if (error || !data) return null;
  return {
    status: data.sync_status as "pending" | "synced" | "failed",
    docNumber: (data.quickbooks_doc_number as string | null) ?? null,
    syncedAt: (data.last_synced_at as string | null) ?? null,
    lastErrorMessage: (data.last_error_message as string | null) ?? null,
  };
}

export async function isPartyMappedToQuickbooks(entityType: "customer" | "broker", entityId: string): Promise<boolean> {
  const supabase = await createClient();
  const { data } = await supabase
    .from("quickbooks_customer_mappings")
    .select("id")
    .eq("local_entity_type", entityType)
    .eq("local_entity_id", entityId)
    .maybeSingle();
  return Boolean(data);
}

// Is QuickBooks connected for the current org? (mirrored into
// integration_settings by 0116's store_/disconnect_ RPCs).
export async function isQuickbooksConnectedForOrg(): Promise<boolean> {
  const supabase = await createClient();
  const { data } = await supabase
    .from("integration_settings")
    .select("is_enabled, disconnected_at, last_connected_at")
    .eq("provider", "quickbooks")
    .maybeSingle();
  return Boolean(data && data.is_enabled && !data.disconnected_at && data.last_connected_at);
}
