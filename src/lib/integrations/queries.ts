import "server-only";
import { createClient } from "@/lib/supabase/server";
import type { IntegrationRow } from "./status";
import type { ProviderId } from "./registry";

const ROW_COLUMNS =
  "id, provider, is_enabled, account_label, external_account_id, last_connected_at, last_tested_at, last_test_status, last_test_message, last_error_code, last_error_message, disconnected_at, last_synced_at, last_sync_status, created_at, updated_at";

export type IntegrationSettingsRow = IntegrationRow & { id: string; provider: ProviderId };

// One org-scoped fetch (RLS-restricted to the caller's own org + owner/
// admin role, 0010) shared by the list page and every provider detail
// page -- never fetched per-card.
export async function getIntegrationRows(supabase: Awaited<ReturnType<typeof createClient>>, organizationId: string): Promise<Map<ProviderId, IntegrationSettingsRow>> {
  const { data } = await supabase.from("integration_settings").select(ROW_COLUMNS).eq("organization_id", organizationId);
  const map = new Map<ProviderId, IntegrationSettingsRow>();
  for (const row of data ?? []) {
    map.set(row.provider as ProviderId, row as unknown as IntegrationSettingsRow);
  }
  return map;
}

export async function getIntegrationActivity(supabase: Awaited<ReturnType<typeof createClient>>, organizationId: string, rowId: string | null, limit = 20) {
  if (!rowId) return [];
  const { data } = await supabase
    .from("activity_logs")
    .select("id, action, changes, actor_id, created_at, profiles(full_name)")
    .eq("organization_id", organizationId)
    .eq("entity_type", "integration")
    .eq("entity_id", rowId)
    .order("created_at", { ascending: false })
    .limit(limit);
  return (data ?? []) as unknown as { id: string; action: string; changes: Record<string, unknown> | null; actor_id: string | null; created_at: string; profiles: { full_name: string } | null }[];
}
