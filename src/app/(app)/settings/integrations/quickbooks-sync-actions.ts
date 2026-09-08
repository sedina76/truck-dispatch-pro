"use server";

import { createHash } from "crypto";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { checkOperationalAccess } from "@/lib/billing/operational-access";
import { getQuickbooksAccessToken } from "./quickbooks-actions";
import {
  queryCustomers,
  getCustomerById,
  createCustomer,
  findOrCreateFreightItem,
  findInvoiceByDocNumber,
  createInvoice,
  type QboCustomer,
} from "@/lib/integrations/providers/quickbooks";

// QuickBooks customer mapping + invoice send MVP (SANDBOX). Every action:
// owner/admin at the app layer, organization resolved from the
// authenticated session (never a browser param), all writes RLS-scoped to
// current_org_id(). No token is returned to the client. Requires migration
// 0117 -- until it is applied, the mapping/sync reads return "table not
// found" which the callers surface as "QuickBooks sync is not set up yet".

const LOCAL_ENTITY_TYPES = new Set(["customer", "broker"]);
const INVOICE_SENDABLE_STATUSES = new Set(["sent", "viewed", "partially_paid", "paid"]);
const STALE_PENDING_MINUTES = 3;

type ActionFail = { ok: false; code: string; message: string };
type ActionResult<T = Record<string, never>> = ({ ok: true } & T) | ActionFail;

async function requireOwnerAdminOrg(): Promise<
  { supabase: Awaited<ReturnType<typeof createClient>>; orgId: string; userId: string | null } | { error: ActionFail }
> {
  const supabase = await createClient();
  const { data: allowed } = await supabase.rpc("has_role", { p_roles: ["owner", "admin"] });
  if (!allowed) return { error: { ok: false, code: "FORBIDDEN", message: "Only an owner or admin can manage QuickBooks sync." } };
  // D.2.11 SaaS paywall -- shared gate for every QuickBooks sync/mapping/export action.
  const billingAccess = await checkOperationalAccess();
  if (!billingAccess.ok) {
    return { error: { ok: false, code: "BILLING_ACCESS_REQUIRED", message: "Your organization's subscription does not permit this action." } };
  }
  let orgId: string;
  try {
    orgId = await getCurrentOrgId();
  } catch {
    return { error: { ok: false, code: "NO_ORG", message: "No organization context." } };
  }
  const {
    data: { user },
  } = await supabase.auth.getUser();
  return { supabase, orgId, userId: user?.id ?? null };
}

function friendlyReauth(): ActionFail {
  return { ok: false, code: "QBO_REAUTH", message: "QuickBooks needs to be reconnected. Open the QuickBooks integration page." };
}

// ---------------------------------------------------------------------------
// Customer mapping
// ---------------------------------------------------------------------------

export async function searchQuickbooksCustomers(term: string): Promise<ActionResult<{ customers: QboCustomer[] }>> {
  const ctx = await requireOwnerAdminOrg();
  if ("error" in ctx) return ctx.error;
  const token = await getQuickbooksAccessToken();
  if (!token) return { ok: false, code: "QBO_DISCONNECTED", message: "QuickBooks is not connected for this organization." };

  const res = await queryCustomers(token.accessToken, token.realmId, term ?? "");
  if (!res.ok) return res.reauthRequired ? friendlyReauth() : { ok: false, code: res.code, message: res.message };
  return { ok: true, customers: res.customers };
}

async function loadLocalEntity(
  supabase: Awaited<ReturnType<typeof createClient>>,
  orgId: string,
  entityType: string,
  entityId: string
): Promise<{ name: string; email: string | null } | null> {
  // customers.company_name is canonical; brokers.legal_name is canonical
  // since 0093 (company_name kept as a legacy mirror).
  const table = entityType === "customer" ? "customers" : "brokers";
  const nameCol = entityType === "customer" ? "company_name" : "legal_name";
  const { data } = await supabase.from(table).select(`${nameCol}, email`).eq("id", entityId).eq("organization_id", orgId).maybeSingle();
  if (!data) return null;
  const row = data as Record<string, unknown>;
  return { name: String(row[nameCol] ?? ""), email: (row.email as string | null) ?? null };
}

export async function mapEntityToQuickbooksCustomer(
  entityType: string,
  entityId: string,
  quickbooksCustomerId: string
): Promise<ActionResult<{ displayName: string }>> {
  const ctx = await requireOwnerAdminOrg();
  if ("error" in ctx) return ctx.error;
  const { supabase, orgId, userId } = ctx;
  if (!LOCAL_ENTITY_TYPES.has(entityType)) return { ok: false, code: "BAD_TYPE", message: "Unsupported record type." };

  const local = await loadLocalEntity(supabase, orgId, entityType, entityId);
  if (!local) return { ok: false, code: "NOT_FOUND", message: "That record is not available." };

  const token = await getQuickbooksAccessToken();
  if (!token) return { ok: false, code: "QBO_DISCONNECTED", message: "QuickBooks is not connected for this organization." };

  const qb = await getCustomerById(token.accessToken, token.realmId, quickbooksCustomerId);
  if (!qb.ok) return qb.reauthRequired ? friendlyReauth() : { ok: false, code: qb.code, message: qb.message };

  const { error } = await supabase.from("quickbooks_customer_mappings").upsert(
    {
      organization_id: orgId,
      local_entity_type: entityType,
      local_entity_id: entityId,
      quickbooks_customer_id: qb.customer.id,
      quickbooks_display_name: qb.customer.displayName,
      quickbooks_sync_token: qb.customer.syncToken,
      created_by: userId,
    },
    { onConflict: "organization_id,local_entity_type,local_entity_id" }
  );
  if (error) {
    if (error.message.includes("quickbooks_customer_mappings_qbo_unique")) {
      return { ok: false, code: "QBO_ALREADY_MAPPED", message: "That QuickBooks customer is already mapped to another record in this organization." };
    }
    if (/relation .* does not exist/i.test(error.message)) {
      return { ok: false, code: "NOT_SET_UP", message: "QuickBooks sync is not set up yet (migration 0117 pending)." };
    }
    return { ok: false, code: "DB_ERROR", message: "Could not save the mapping." };
  }

  await supabase.rpc("log_activity", {
    p_entity_type: entityType,
    p_entity_id: entityId,
    p_action: "quickbooks_customer_mapped",
    p_changes: { quickbooks_customer_id: qb.customer.id, quickbooks_display_name: qb.customer.displayName },
    p_organization_id: orgId,
  });

  revalidatePath(`/${entityType === "customer" ? "customers" : "brokers"}/${entityId}`);
  return { ok: true, displayName: qb.customer.displayName };
}

export async function createQuickbooksCustomerForEntity(
  entityType: string,
  entityId: string
): Promise<ActionResult<{ displayName: string; adopted: boolean }>> {
  const ctx = await requireOwnerAdminOrg();
  if ("error" in ctx) return ctx.error;
  const { supabase, orgId, userId } = ctx;
  if (!LOCAL_ENTITY_TYPES.has(entityType)) return { ok: false, code: "BAD_TYPE", message: "Unsupported record type." };

  const local = await loadLocalEntity(supabase, orgId, entityType, entityId);
  if (!local) return { ok: false, code: "NOT_FOUND", message: "That record is not available." };

  // Refuse if already mapped.
  const { data: existing } = await supabase
    .from("quickbooks_customer_mappings")
    .select("quickbooks_display_name")
    .eq("organization_id", orgId)
    .eq("local_entity_type", entityType)
    .eq("local_entity_id", entityId)
    .maybeSingle();
  if (existing) return { ok: false, code: "ALREADY_MAPPED", message: "This record is already mapped to QuickBooks." };

  const token = await getQuickbooksAccessToken();
  if (!token) return { ok: false, code: "QBO_DISCONNECTED", message: "QuickBooks is not connected for this organization." };

  const created = await createCustomer(token.accessToken, token.realmId, {
    displayName: local.name,
    companyName: local.name,
    email: local.email,
  });
  if (!created.ok) return created.reauthRequired ? friendlyReauth() : { ok: false, code: created.code, message: created.message };

  const { error } = await supabase.from("quickbooks_customer_mappings").insert({
    organization_id: orgId,
    local_entity_type: entityType,
    local_entity_id: entityId,
    quickbooks_customer_id: created.customer.id,
    quickbooks_display_name: created.customer.displayName,
    quickbooks_sync_token: created.customer.syncToken,
    created_by: userId,
  });
  if (error) {
    // QuickBooks customer exists but local persistence failed -- partial
    // state. Report it; the customer id is safe to show for repair.
    if (/relation .* does not exist/i.test(error.message)) {
      return { ok: false, code: "NOT_SET_UP", message: "QuickBooks sync is not set up yet (migration 0117 pending)." };
    }
    return {
      ok: false,
      code: "PARTIAL_CREATE",
      message: `A QuickBooks customer "${created.customer.displayName}" (id ${created.customer.id}) was created but could not be saved locally. Use "Map to QuickBooks" and select it to finish.`,
    };
  }

  await supabase.rpc("log_activity", {
    p_entity_type: entityType,
    p_entity_id: entityId,
    p_action: created.adopted ? "quickbooks_customer_mapped" : "quickbooks_customer_created",
    p_changes: { quickbooks_customer_id: created.customer.id, quickbooks_display_name: created.customer.displayName, adopted: created.adopted },
    p_organization_id: orgId,
  });

  revalidatePath(`/${entityType === "customer" ? "customers" : "brokers"}/${entityId}`);
  return { ok: true, displayName: created.customer.displayName, adopted: created.adopted };
}

// ---------------------------------------------------------------------------
// Invoice send
// ---------------------------------------------------------------------------

type LoadStop = { stop_type: string; stop_sequence: number; city: string | null; state: string | null };

function buildLineDescription(loadNumber: string | null, stops: LoadStop[] | null): string {
  const parts = ["Freight Transportation"];
  if (loadNumber) parts.push(`Load #${loadNumber}`);
  const s = stops ?? [];
  const pickup = s.filter((x) => x.stop_type === "pickup").sort((a, b) => a.stop_sequence - b.stop_sequence)[0];
  const delivery = s.filter((x) => x.stop_type === "delivery").sort((a, b) => b.stop_sequence - a.stop_sequence)[0];
  const cityState = (x?: LoadStop) => (x && x.city && x.state ? `${x.city}, ${x.state}` : x?.city || x?.state || null);
  const from = cityState(pickup);
  const to = cityState(delivery);
  if (from && to) parts.push(`${from} → ${to}`);
  return parts.join("\n");
}

async function getOrgFreightItemId(
  supabase: Awaited<ReturnType<typeof createClient>>,
  orgId: string,
  accessToken: string,
  realmId: string
): Promise<{ itemId: string } | { error: ActionFail }> {
  const { data: row } = await supabase
    .from("integration_settings")
    .select("id, config")
    .eq("organization_id", orgId)
    .eq("provider", "quickbooks")
    .maybeSingle();
  const cfg = (row?.config ?? {}) as { quickbooks?: { freight_item_id?: string } };
  const existing = cfg.quickbooks?.freight_item_id;
  if (existing) return { itemId: existing };

  const item = await findOrCreateFreightItem(accessToken, realmId);
  if (!item.ok) {
    return { error: item.reauthRequired ? friendlyReauth() : { ok: false, code: item.code, message: item.message } };
  }
  if (row?.id) {
    await supabase
      .from("integration_settings")
      .update({ config: { ...(row.config as object), quickbooks: { ...(cfg.quickbooks ?? {}), freight_item_id: item.itemId } } })
      .eq("id", row.id);
  }
  return { itemId: item.itemId };
}

export async function sendInvoiceToQuickbooks(
  invoiceId: string
): Promise<ActionResult<{ alreadySynced: boolean; docNumber: string | null; syncedAt: string | null }>> {
  const ctx = await requireOwnerAdminOrg();
  if ("error" in ctx) return ctx.error;
  const { supabase, orgId, userId } = ctx;

  const { data: inv } = await supabase
    .from("invoices")
    .select(
      "id, organization_id, invoice_number, status, broker_id, customer_id, total_amount, issue_date, due_date, bill_to_email, load_id, " +
        "loads(load_number, load_stops(stop_type, stop_sequence, city, state))"
    )
    .eq("id", invoiceId)
    .eq("organization_id", orgId)
    .maybeSingle();
  if (!inv) return { ok: false, code: "NOT_FOUND", message: "This invoice is not available." };

  const invoice = inv as unknown as {
    id: string;
    invoice_number: string;
    status: string;
    broker_id: string | null;
    customer_id: string | null;
    total_amount: number;
    issue_date: string;
    due_date: string | null;
    bill_to_email: string | null;
    loads: { load_number: string | null; load_stops: LoadStop[] | null } | null;
  };

  // ---- Validation (spec Phase 3) ----
  if (!INVOICE_SENDABLE_STATUSES.has(invoice.status)) {
    return { ok: false, code: "BAD_STATUS", message: "Only an issued invoice (Sent, Viewed, Partially Paid, or Paid) can be sent to QuickBooks." };
  }
  if (!(Number(invoice.total_amount) > 0)) {
    return { ok: false, code: "ZERO_TOTAL", message: "This invoice's total is zero -- nothing to send." };
  }
  const partyType = invoice.broker_id ? "broker" : invoice.customer_id ? "customer" : null;
  const partyId = invoice.broker_id ?? invoice.customer_id ?? null;
  if (!partyType || !partyId) {
    return { ok: false, code: "NO_PARTY", message: "This invoice has no customer or broker." };
  }

  const { data: mapping, error: mapErr } = await supabase
    .from("quickbooks_customer_mappings")
    .select("quickbooks_customer_id")
    .eq("organization_id", orgId)
    .eq("local_entity_type", partyType)
    .eq("local_entity_id", partyId)
    .maybeSingle();
  if (mapErr && /relation .* does not exist/i.test(mapErr.message)) {
    return { ok: false, code: "NOT_SET_UP", message: "QuickBooks sync is not set up yet (migration 0117 pending)." };
  }
  if (!mapping) {
    return { ok: false, code: "CUSTOMER_NOT_MAPPED", message: "Map this customer to QuickBooks first." };
  }

  const token = await getQuickbooksAccessToken();
  if (!token) return { ok: false, code: "QBO_DISCONNECTED", message: "QuickBooks is not connected for this organization." };

  // ---- Idempotent sync row (the lock) ----
  const { data: syncRow, error: insErr } = await supabase
    .from("quickbooks_invoice_syncs")
    .insert({ organization_id: orgId, invoice_id: invoice.id, sync_status: "pending", created_by: userId })
    .select("id, sync_status, quickbooks_doc_number, last_synced_at, updated_at")
    .single();

  let syncId: string;
  if (insErr) {
    if (/relation .* does not exist/i.test(insErr.message)) {
      return { ok: false, code: "NOT_SET_UP", message: "QuickBooks sync is not set up yet (migration 0117 pending)." };
    }
    if (insErr.code !== "23505") return { ok: false, code: "DB_ERROR", message: "Could not start the QuickBooks sync." };
    // A sync row already exists.
    const { data: existing } = await supabase
      .from("quickbooks_invoice_syncs")
      .select("id, sync_status, quickbooks_doc_number, quickbooks_invoice_id, last_synced_at, updated_at")
      .eq("organization_id", orgId)
      .eq("invoice_id", invoice.id)
      .single();
    if (!existing) return { ok: false, code: "DB_ERROR", message: "Could not read the QuickBooks sync state." };
    if (existing.sync_status === "synced") {
      return { ok: true, alreadySynced: true, docNumber: existing.quickbooks_doc_number, syncedAt: existing.last_synced_at };
    }
    const stale = Date.now() - new Date(existing.updated_at).getTime() > STALE_PENDING_MINUTES * 60_000;
    if (existing.sync_status === "pending" && !stale) {
      return { ok: false, code: "IN_PROGRESS", message: "This invoice is already being sent to QuickBooks. Refresh in a moment." };
    }
    // failed, or a stale pending -> reclaim for a retry.
    syncId = existing.id;
    await supabase.from("quickbooks_invoice_syncs").update({ sync_status: "pending", last_error_code: null, last_error_message: null }).eq("id", syncId);
  } else {
    syncId = syncRow.id;
  }

  async function markFailed(code: string, message: string): Promise<ActionResult<{ alreadySynced: boolean; docNumber: string | null; syncedAt: string | null }>> {
    await supabase
      .from("quickbooks_invoice_syncs")
      .update({ sync_status: "failed", last_error_code: code.slice(0, 60), last_error_message: message.slice(0, 500) })
      .eq("id", syncId);
    return { ok: false, code, message };
  }

  // ---- Freight service item (one per org) ----
  const itemRes = await getOrgFreightItemId(supabase, orgId, token.accessToken, token.realmId);
  if ("error" in itemRes) return markFailed(itemRes.error.code, itemRes.error.message);

  // ---- Payload ----
  const docNumber = invoice.invoice_number.slice(0, 21);
  const lineDescription = buildLineDescription(invoice.loads?.load_number ?? null, invoice.loads?.load_stops ?? null);
  const amount = Number(Number(invoice.total_amount).toFixed(2));
  const payloadHash = createHash("sha256")
    .update(JSON.stringify({ c: mapping.quickbooks_customer_id, i: itemRes.itemId, d: docNumber, t: invoice.issue_date, u: invoice.due_date, a: amount, l: lineDescription }))
    .digest("hex");

  // ---- Adopt an existing QBO invoice with this DocNumber (partial-failure safety) ----
  const found = await findInvoiceByDocNumber(token.accessToken, token.realmId, docNumber);
  if (!found.ok) return found.reauthRequired ? friendlyReauth() : markFailed(found.code, found.message);
  if (found.invoice) {
    const nowIso = new Date().toISOString();
    await supabase
      .from("quickbooks_invoice_syncs")
      .update({
        sync_status: "synced",
        quickbooks_invoice_id: found.invoice.id,
        quickbooks_doc_number: found.invoice.docNumber,
        quickbooks_sync_token: found.invoice.syncToken,
        payload_hash: payloadHash,
        last_synced_at: nowIso,
        last_error_code: null,
        last_error_message: null,
      })
      .eq("id", syncId);
    await supabase.rpc("log_activity", {
      p_entity_type: "invoice",
      p_entity_id: invoice.id,
      p_action: "quickbooks_invoice_synced",
      p_changes: { quickbooks_invoice_id: found.invoice.id, doc_number: found.invoice.docNumber, adopted: true },
      p_organization_id: orgId,
    });
    revalidatePath(`/invoices/${invoice.id}`);
    return { ok: true, alreadySynced: true, docNumber: found.invoice.docNumber, syncedAt: nowIso };
  }

  // ---- Create ----
  const created = await createInvoice(token.accessToken, token.realmId, {
    customerId: mapping.quickbooks_customer_id,
    itemId: itemRes.itemId,
    docNumber,
    txnDate: invoice.issue_date,
    dueDate: invoice.due_date,
    lineDescription,
    amount,
    customerEmail: invoice.bill_to_email,
  });
  if (!created.ok) return created.reauthRequired ? friendlyReauth() : markFailed(created.code, created.message);

  const nowIso = new Date().toISOString();
  const { error: finErr } = await supabase
    .from("quickbooks_invoice_syncs")
    .update({
      sync_status: "synced",
      quickbooks_invoice_id: created.invoice.id,
      quickbooks_doc_number: created.invoice.docNumber,
      quickbooks_sync_token: created.invoice.syncToken,
      payload_hash: payloadHash,
      last_synced_at: nowIso,
      last_error_code: null,
      last_error_message: null,
    })
    .eq("id", syncId);
  if (finErr) {
    // QBO invoice created but local persistence failed. NOT marked failed
    // (a retry would find it via DocNumber and adopt it). Report clearly.
    return {
      ok: false,
      code: "PARTIAL_SYNC",
      message: `The QuickBooks invoice was created (id ${created.invoice.id}) but the local record could not be updated. Click "Send to QuickBooks" again -- it will adopt the existing invoice, not create a duplicate.`,
    };
  }

  await supabase.rpc("log_activity", {
    p_entity_type: "invoice",
    p_entity_id: invoice.id,
    p_action: "quickbooks_invoice_synced",
    p_changes: { quickbooks_invoice_id: created.invoice.id, doc_number: created.invoice.docNumber, adopted: false },
    p_organization_id: orgId,
  });

  revalidatePath(`/invoices/${invoice.id}`);
  return { ok: true, alreadySynced: false, docNumber: created.invoice.docNumber, syncedAt: nowIso };
}
