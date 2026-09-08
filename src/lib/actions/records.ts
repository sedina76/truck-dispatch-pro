"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { requireOperationalAccess } from "@/lib/billing/operational-access";

// Allow-list guards against an arbitrary table name ever reaching a raw
// Supabase query from these generic helpers. RLS is still the real
// authorization boundary (a role without delete rights simply affects 0
// rows) -- this list only prevents programmer error / unintended tables.
const MANAGED_TABLES = new Set([
  "carriers",
  "brokers",
  "customers",
  "drivers",
  "trucks",
  "trailers",
  "loads",
  "dispatches",
  "invoices",
  "payments",
  "settlements",
  "documents",
  "compliance_items",
  "tasks",
  "notes",
  "integration_settings",
  "maintenance_records",
  "fuel_logs",
  "dispatch_advances",
  "organization_bank_accounts",
  "insurance_policies",
  "dot_violations",
]);

function assertManaged(table: string) {
  if (!MANAGED_TABLES.has(table)) {
    throw new Error(`Table "${table}" is not in the managed CRUD allow-list.`);
  }
}

// Subset of MANAGED_TABLES that maps onto a public.entity_type enum value --
// that's what feeds the dashboard's "Recent Activity" feed via log_activity().
// Tables with no matching enum value (documents, payments, tasks, ...) are
// simply not logged; there's no generic/catch-all entity_type to log them as.
const ENTITY_TYPE_BY_TABLE: Record<string, string> = {
  carriers: "carrier",
  brokers: "broker",
  customers: "customer",
  drivers: "driver",
  trucks: "truck",
  trailers: "trailer",
  loads: "load",
  dispatches: "dispatch",
  invoices: "invoice",
  settlements: "settlement",
};

async function logActivity(table: string, id: string, action: "created" | "updated" | "deleted") {
  const entityType = ENTITY_TYPE_BY_TABLE[table];
  if (!entityType) return;
  const supabase = await createClient();
  await supabase.rpc("log_activity", { p_entity_type: entityType, p_entity_id: id, p_action: action });
}

// Every tenant table has a NOT NULL organization_id with no default -- RLS
// only ever *validates* that column against public.current_org_id(), it
// can't populate it. Every insert must supply it explicitly, so this is
// centralized here rather than duplicated in each entity's actions.ts.
export async function getCurrentOrgId(): Promise<string> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("current_org_id");
  if (error || !data) {
    throw new Error("Could not determine the current organization for this user.");
  }
  return data as string;
}

export async function deleteRecord(table: string, id: string, redirectPath: string) {
  assertManaged(table);
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  await supabase.from(table).delete().eq("id", id);
  await logActivity(table, id, "deleted");
  revalidatePath(redirectPath);
}

export async function insertRecord(
  table: string,
  values: Record<string, unknown>,
  redirectPath: string
) {
  assertManaged(table);
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const { data, error } = await supabase
    .from(table)
    .insert({ ...values, organization_id: organizationId })
    .select("id")
    .single();
  if (error) throw new Error(error.message);
  await logActivity(table, data.id, "created");
  revalidatePath(redirectPath);
  redirect(redirectPath);
}

export async function updateRecord(
  table: string,
  id: string,
  values: Record<string, unknown>,
  redirectPath: string
) {
  assertManaged(table);
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const { error } = await supabase.from(table).update(values).eq("id", id);
  if (error) throw new Error(error.message);
  await logActivity(table, id, "updated");
  revalidatePath(redirectPath);
  redirect(redirectPath);
}

// Same as updateRecord but stays on the current page -- for in-place updates
// like a kanban drag-and-drop status change, where a redirect would be
// jarring and RSC re-fetch via revalidatePath is all that's needed.
export async function updateRecordInPlace(
  table: string,
  id: string,
  values: Record<string, unknown>,
  revalidatePathTarget: string
) {
  assertManaged(table);
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const { error } = await supabase.from(table).update(values).eq("id", id);
  if (error) throw new Error(error.message);
  await logActivity(table, id, "updated");
  revalidatePath(revalidatePathTarget);
}
