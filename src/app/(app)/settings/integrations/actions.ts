"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { PROVIDER_BY_ID, isProviderId, type ProviderId } from "@/lib/integrations/registry";
import { testResendConnection } from "@/lib/integrations/providers/resend";

// Every management action here does BOTH of the two things spec sections
// 30/46 ask for -- not one or the other:
//   1. RLS (0010_rls_policies.sql, unchanged) is the real, unconditional
//      backstop: integration_settings SELECT/INSERT/UPDATE/DELETE already
//      require organization_id = current_org_id() AND has_role([owner,
//      admin]) at the database layer, so a crafted request can never touch
//      another org's row or bypass the role check no matter what this file
//      does.
//   2. An explicit app-level role check below, so a non-owner/admin gets a
//      clear "not allowed" error immediately rather than a confusing RLS
//      no-op/empty-result.
// Every action re-verifies the provider id against the registry and checks
// `implemented` server-side too -- the UI hides Test/Enable for
// unimplemented providers, but that's UX only, never the real gate.

async function requireOwnerOrAdmin(supabase: Awaited<ReturnType<typeof createClient>>) {
  const { data: allowed } = await supabase.rpc("has_role", { p_roles: ["owner", "admin"] });
  if (!allowed) throw new Error("Only an owner or admin can manage integrations.");
}

function requireProvider(provider: string): ProviderId {
  if (!isProviderId(provider)) throw new Error("Unknown provider.");
  return provider;
}

async function logIntegrationActivity(
  supabase: Awaited<ReturnType<typeof createClient>>,
  organizationId: string,
  rowId: string,
  action: string,
  changes: Record<string, unknown> | null = null
) {
  // Never logs secrets -- changes is always a small, non-secret summary
  // (e.g. { provider: "resend" }), never credential values.
  await supabase.rpc("log_activity", { p_entity_type: "integration", p_entity_id: rowId, p_action: action, p_changes: changes, p_organization_id: organizationId });
}

async function getOrCreateRow(supabase: Awaited<ReturnType<typeof createClient>>, organizationId: string, provider: ProviderId, userId: string | null) {
  const { data: existing } = await supabase.from("integration_settings").select("id").eq("organization_id", organizationId).eq("provider", provider).maybeSingle();
  if (existing) return existing.id as string;
  const { data: created, error } = await supabase
    .from("integration_settings")
    .insert({ organization_id: organizationId, provider, is_enabled: false, created_by: userId, updated_by: userId })
    .select("id")
    .single();
  if (error) throw new Error(error.message);
  return created.id as string;
}

// Real, provider-specific test (spec section 22). Only Resend has one
// today -- every other provider's supportsTest is false in the registry,
// and this function refuses to run for them even if called directly.
// Returns void (not the TestResult) because this is bound directly as a
// <form action> -- the real result is persisted to integration_settings
// below and read back on the next render via revalidatePath, not returned
// to the caller.
export async function testConnection(providerId: string): Promise<void> {
  const provider = requireProvider(providerId);
  const def = PROVIDER_BY_ID[provider];
  if (!def.implemented || !def.supportsTest) {
    throw new Error(`${def.name} does not support connection testing.`);
  }

  const supabase = await createClient();
  await requireOwnerOrAdmin(supabase);
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const rowId = await getOrCreateRow(supabase, organizationId, provider, user?.id ?? null);

  const result = provider === "resend" ? await testResendConnection() : { ok: false as const, message: "No test implemented.", errorCode: "NOT_IMPLEMENTED" };

  const now = new Date().toISOString();
  if (result.ok) {
    await supabase
      .from("integration_settings")
      .update({
        last_tested_at: now,
        last_test_status: "success",
        last_test_message: result.message,
        last_error_code: null,
        last_error_message: null,
        last_connected_at: now,
        account_label: result.accountLabel,
        updated_by: user?.id ?? null,
      })
      .eq("id", rowId);
    await logIntegrationActivity(supabase, organizationId, rowId, "connection_test_succeeded", { provider });
  } else {
    await supabase
      .from("integration_settings")
      .update({
        last_tested_at: now,
        last_test_status: "failure",
        last_test_message: result.message,
        last_error_code: result.errorCode,
        last_error_message: result.message,
        updated_by: user?.id ?? null,
      })
      .eq("id", rowId);
    await logIntegrationActivity(supabase, organizationId, rowId, "connection_test_failed", { provider });
  }

  revalidatePath("/settings/integrations");
  revalidatePath(`/settings/integrations/${provider}`);
}

// Replaces the old toggleIntegration/enableIntegration: explicit verb,
// explicit implemented-gate, explicit role check, real audit log entry --
// spec section 34 (Disable keeps configuration, only stops operations;
// never the same code path as Disconnect below).
export async function setIntegrationEnabled(providerId: string, enabled: boolean) {
  const provider = requireProvider(providerId);
  const def = PROVIDER_BY_ID[provider];
  if (!def.implemented) throw new Error(`${def.name} is not yet available to enable.`);
  // QuickBooks is enabled/disabled implicitly by its own connect/disconnect
  // flow (which also owns token revoke). The generic per-org toggle here
  // must never touch its integration_settings row -- that would desync it
  // from quickbooks_connections. The UI does not offer this for QuickBooks;
  // this rejects a forged/stale call.
  if (provider === "quickbooks") throw new Error("Manage the QuickBooks connection from its own page.");

  const supabase = await createClient();
  await requireOwnerOrAdmin(supabase);
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const rowId = await getOrCreateRow(supabase, organizationId, provider, user?.id ?? null);
  await supabase.from("integration_settings").update({ is_enabled: enabled, updated_by: user?.id ?? null }).eq("id", rowId);
  await logIntegrationActivity(supabase, organizationId, rowId, enabled ? "integration_enabled" : "integration_disabled", { provider });

  revalidatePath("/settings/integrations");
  revalidatePath(`/settings/integrations/${provider}`);
}

// Disconnect (spec section 33/34): distinct from Disable. Clears the
// connection-identifying fields (nothing to revoke server-side for any
// currently-implemented provider -- Resend has no per-org token, only a
// platform-wide env var) and turns the integration off, but preserves
// last_test_*/timestamps and the full activity-log history -- never a hard
// delete.
export async function disconnectIntegration(providerId: string) {
  const provider = requireProvider(providerId);
  const def = PROVIDER_BY_ID[provider];
  if (!def.implemented) throw new Error(`${def.name} is not connected.`);
  // QuickBooks disconnect must go through disconnectQuickbooks() (revokes
  // the token at Intuit + tears down quickbooks_connections). The generic
  // disconnect here would only clear integration_settings and leave live
  // encrypted tokens behind. Not offered in the UI for QuickBooks; reject
  // a forged/stale call.
  if (provider === "quickbooks") throw new Error("Disconnect QuickBooks from its own page.");

  const supabase = await createClient();
  await requireOwnerOrAdmin(supabase);
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const rowId = await getOrCreateRow(supabase, organizationId, provider, user?.id ?? null);
  await supabase
    .from("integration_settings")
    .update({
      is_enabled: false,
      disconnected_at: new Date().toISOString(),
      account_label: null,
      external_account_id: null,
      updated_by: user?.id ?? null,
    })
    .eq("id", rowId);
  await logIntegrationActivity(supabase, organizationId, rowId, "integration_disconnected", { provider });

  revalidatePath("/settings/integrations");
  revalidatePath(`/settings/integrations/${provider}`);
}
