"use server";

import { revalidatePath } from "next/cache";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { getCurrentDispatch, DISPATCH_STATUS_ORDER } from "@/lib/driver-portal/dashboard-data";
import { DRIVER_SUBMITTABLE_CATEGORIES } from "@/lib/driver-portal/constants";
import { emptyToNull, toNumber } from "@/lib/utils/form";

// Every action here follows the same rule (spec section 31): resolve the
// authenticated driver-portal session FIRST, then verify ownership of
// whatever record is being touched server-side -- never trust an id the
// browser sent. The driver portal has no Supabase Auth session at all, so
// there is no RLS to lean on for these writes; the service-role client is
// used deliberately, with the ownership check standing in for RLS, exactly
// like every other driver-portal route already in this codebase
// (upload-pod, location).

async function requireIdentity() {
  const identity = await getDriverPortalSession();
  if (!identity) throw new Error("Not signed in.");
  return identity;
}

// ---------------------------------------------------------------------------
// Status update. Reuses the exact same dispatches.status column and the
// exact same DB triggers staff already rely on
// (dispatches_sync_load_status -> auto_generate_invoice_on_delivery,
// 0028_auto_invoice_dispatch_sync_fix.sql) -- this action never touches
// loads or invoices directly. Forward-only transition, validated
// server-side against DISPATCH_STATUS_ORDER; no new status enum invented.
// ---------------------------------------------------------------------------
export async function updateMyDispatchStatus(dispatchId: string, targetStatus: string) {
  const identity = await requireIdentity();
  const supabase = createServiceRoleClient();

  const { data: dispatch } = await supabase
    .from("dispatches")
    .select("id, status, driver_id, organization_id")
    .eq("id", dispatchId)
    .maybeSingle();
  if (!dispatch || dispatch.driver_id !== identity.driverId || dispatch.organization_id !== identity.organizationId) {
    throw new Error("This trip is not assigned to you.");
  }

  const currentIdx = DISPATCH_STATUS_ORDER.indexOf(dispatch.status as (typeof DISPATCH_STATUS_ORDER)[number]);
  const targetIdx = DISPATCH_STATUS_ORDER.indexOf(targetStatus as (typeof DISPATCH_STATUS_ORDER)[number]);
  if (targetIdx === -1) throw new Error("Unsupported status.");
  if (currentIdx === -1 || targetIdx <= currentIdx) {
    throw new Error("Status can only move forward, one trip at a time.");
  }

  const { error } = await supabase.from("dispatches").update({ status: targetStatus }).eq("id", dispatchId);
  if (error) throw new Error(error.message);

  // Status History (spec section 4/6): load_tracking_events already exists
  // for exactly this purpose (staff check-calls, dispatcher-side status
  // changes) -- source='driver_app' distinguishes this from a manual
  // dispatcher entry without inventing a new table.
  //
  // IMPORTANT: load_tracking_events.status is typed public.load_status, a
  // DIFFERENT enum from public.dispatch_status -- several dispatch
  // statuses (accepted, en_route_to_pickup, loaded, en_route_to_delivery,
  // completed) are not valid load_status members at all. Found live: every
  // one of these inserts was silently failing (its error was never
  // checked) whenever the target wasn't one of the few spellings the two
  // enums happen to share. Rather than force a lossy dispatch->load status
  // mapping into a column that means something more specific, the target
  // is recorded as readable text in notes and status is left null.
  const dispatchRow = await supabase.from("dispatches").select("load_id").eq("id", dispatchId).single();
  if (dispatchRow.data) {
    const { error: trackingError } = await supabase.from("load_tracking_events").insert({
      organization_id: identity.organizationId,
      load_id: dispatchRow.data.load_id,
      dispatch_id: dispatchId,
      status: null,
      source: "driver_app",
      reported_by: null, // no profiles row for a driver-portal session
      notes: `Driver status: ${targetStatus.replace(/_/g, " ")}`,
    });
    // Deliberately non-fatal: a Status History entry is a nice-to-have,
    // never worth rolling back a real status update the driver just made.
    if (trackingError) console.error("load_tracking_events insert failed:", trackingError.message);
  }

  revalidatePath("/driver-portal");
  revalidatePath("/driver-portal/trip");
}

// ---------------------------------------------------------------------------
// Expense submission. Reuses the existing expenses table/enums/triggers
// (0040_expense_cost_management.sql) -- no second driver-expense system.
// The load is NEVER taken from client input; it is re-resolved from the
// driver's own current dispatch server-side every time (spec section 12:
// "The driver should not manually browse all company loads").
// ---------------------------------------------------------------------------
export async function submitDriverExpense(formData: FormData): Promise<{ expenseId: string }> {
  const identity = await requireIdentity();
  const supabase = createServiceRoleClient();

  const dispatch = await getCurrentDispatch(supabase, identity.driverId);
  if (!dispatch || !dispatch.load_id) {
    throw new Error("No trip to submit this expense against.");
  }

  const category = String(formData.get("category") || "");
  if (!(DRIVER_SUBMITTABLE_CATEGORIES as readonly string[]).includes(category)) {
    throw new Error("Unsupported expense category.");
  }
  const amount = toNumber(formData.get("amount"));
  if (!amount || amount <= 0) throw new Error("Enter a valid amount.");

  const { data, error } = await supabase
    .from("expenses")
    .insert({
      organization_id: identity.organizationId,
      scope: "load",
      load_id: dispatch.load_id,
      driver_id: identity.driverId,
      category,
      amount,
      expense_date: String(formData.get("expense_date") || new Date().toISOString().slice(0, 10)),
      vendor_name: emptyToNull(formData.get("vendor_name")),
      reference_number: emptyToNull(formData.get("reference_number")),
      notes: emptyToNull(formData.get("notes")),
      status: "submitted",
      recorded_by: null, // drivers have no profiles row -- see upload-pod's uploaded_by for the same rationale
    })
    .select("id")
    .single();
  if (error) throw new Error(error.message);

  revalidatePath("/driver-portal/expenses");
  revalidatePath("/driver-portal");
  return { expenseId: data.id };
}

const RECEIPT_ALLOWED_TYPES = new Set(["application/pdf", "image/jpeg", "image/png"]);
const RECEIPT_DOCUMENT_TYPES = new Set(["expense_receipt", "fuel_receipt", "toll_receipt", "lumper_receipt", "scale_ticket", "other"]);
const MAX_BYTES = 15 * 1024 * 1024;

export async function uploadDriverExpenseReceipt(expenseId: string, documentType: string, formData: FormData) {
  const identity = await requireIdentity();
  if (!RECEIPT_DOCUMENT_TYPES.has(documentType)) throw new Error(`Unsupported document type: ${documentType}`);

  const file = formData.get("file");
  if (!(file instanceof File)) throw new Error("No file provided.");
  if (file.size > MAX_BYTES) throw new Error("File is too large (15 MB max).");
  if (!RECEIPT_ALLOWED_TYPES.has(file.type)) throw new Error("Unsupported file type. Use PDF, JPG, or PNG.");

  const supabase = createServiceRoleClient();
  const { data: expense } = await supabase
    .from("expenses")
    .select("id, organization_id, driver_id")
    .eq("id", expenseId)
    .maybeSingle();
  if (!expense || expense.driver_id !== identity.driverId || expense.organization_id !== identity.organizationId) {
    throw new Error("Expense not found.");
  }

  const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-100);
  const storagePath = `${identity.organizationId}/${expenseId}/${Date.now()}_${safeName}`;

  const { error: uploadError } = await supabase.storage
    .from("expense-documents")
    .upload(storagePath, await file.arrayBuffer(), { contentType: file.type, upsert: false });
  if (uploadError) throw new Error(uploadError.message);

  const { data: doc, error: insertError } = await supabase
    .from("documents")
    .insert({
      organization_id: identity.organizationId,
      entity_type: "expense",
      entity_id: expenseId,
      document_type: documentType,
      file_name: file.name,
      file_path: storagePath,
      file_size_bytes: file.size,
      mime_type: file.type,
      uploaded_by: null,
    })
    .select("id")
    .single();
  if (insertError) throw new Error(insertError.message);

  const { error: linkError } = await supabase.from("expenses").update({ receipt_document_id: doc.id }).eq("id", expenseId);
  if (linkError) throw new Error(linkError.message);

  revalidatePath(`/driver-portal/expenses/${expenseId}`);
}

// SECURITY: storagePath comes from the client (a form action's bound
// argument) -- a Server Action is a real, directly-callable HTTP endpoint
// in its own right, reachable with an arbitrary string regardless of what
// the UI normally sends. Never mint a signed URL from a caller-supplied
// path alone: resolve it to a real `documents` row first, then verify
// ownership (the underlying expense belongs to THIS driver, in THIS
// driver's org) before signing anything. A path that doesn't resolve to an
// owned row gets a generic "not found," never a signed URL.
export async function getDriverExpenseReceiptSignedUrl(storagePath: string, download: boolean): Promise<string> {
  const identity = await requireIdentity();
  const supabase = createServiceRoleClient();

  const { data: doc } = await supabase
    .from("documents")
    .select("id, entity_type, entity_id, organization_id")
    .eq("file_path", storagePath)
    .eq("entity_type", "expense")
    .eq("organization_id", identity.organizationId)
    .maybeSingle();
  if (!doc) throw new Error("Document not found.");

  const { data: expense } = await supabase
    .from("expenses")
    .select("id, driver_id, organization_id")
    .eq("id", doc.entity_id)
    .maybeSingle();
  if (!expense || expense.driver_id !== identity.driverId || expense.organization_id !== identity.organizationId) {
    throw new Error("Document not found.");
  }

  const { data, error } = await supabase.storage.from("expense-documents").createSignedUrl(storagePath, 300, download ? { download: true } : undefined);
  if (error || !data) throw new Error(error?.message ?? "Could not generate a download link.");
  return data.signedUrl;
}

// ---------------------------------------------------------------------------
// Trip documents (BOL/lumper/scale ticket/fuel receipt/other) -- separate
// from the existing POD upload path (upload-pod/route.ts, untouched).
// Reuses the same load-documents bucket and polymorphic documents table.
// ---------------------------------------------------------------------------
const TRIP_DOCUMENT_TYPES = new Set(["bol", "lumper_receipt", "scale_ticket", "fuel_receipt", "other"]);

export async function uploadTripDocument(loadId: string, documentType: string, formData: FormData) {
  const identity = await requireIdentity();
  if (!TRIP_DOCUMENT_TYPES.has(documentType)) throw new Error(`Unsupported document type: ${documentType}`);

  const file = formData.get("file");
  if (!(file instanceof File)) throw new Error("No file provided.");
  if (file.size > MAX_BYTES) throw new Error("File is too large (15 MB max).");
  if (!RECEIPT_ALLOWED_TYPES.has(file.type)) throw new Error("Unsupported file type. Use PDF, JPG, or PNG.");

  const supabase = createServiceRoleClient();
  const { data: dispatch } = await supabase
    .from("dispatches")
    .select("id")
    .eq("load_id", loadId)
    .eq("driver_id", identity.driverId)
    .maybeSingle();
  if (!dispatch) throw new Error("This load is not assigned to you.");

  const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-100);
  const storagePath = `${identity.organizationId}/${loadId}/${Date.now()}_${safeName}`;

  const { error: uploadError } = await supabase.storage
    .from("load-documents")
    .upload(storagePath, await file.arrayBuffer(), { contentType: file.type, upsert: false });
  if (uploadError) throw new Error(uploadError.message);

  const { error: insertError } = await supabase.from("documents").insert({
    organization_id: identity.organizationId,
    entity_type: "load",
    entity_id: loadId,
    document_type: documentType,
    file_name: file.name,
    file_path: storagePath,
    file_size_bytes: file.size,
    mime_type: file.type,
    uploaded_by: null,
  });
  if (insertError) throw new Error(insertError.message);

  revalidatePath("/driver-portal/documents");
  revalidatePath("/driver-portal/trip");
}

// SECURITY (critical): the `load-documents` bucket holds BOTH driver-safe
// operational documents (BOL, lumper receipt, scale ticket, fuel receipt)
// AND strictly staff-only financial documents (rate_confirmation, and POD
// verification metadata) for every load in the org. Before this fix,
// `storagePath` was signed with no ownership or document-type check at
// all -- any driver-portal session could request a signed URL for ANY
// path in the bucket, including a rate confirmation's real path, simply by
// knowing or guessing it. Now: resolve to a real `documents` row, require
// `document_type` to be in the driver-safe allowlist (rate_confirmation is
// deliberately never in this set), and require the underlying load to be
// assigned to THIS driver via a real dispatch, in THIS driver's org. Any
// mismatch returns a generic "not found," never a signed URL.
export async function getTripDocumentSignedUrl(storagePath: string, download: boolean): Promise<string> {
  const identity = await requireIdentity();
  const supabase = createServiceRoleClient();

  const { data: doc } = await supabase
    .from("documents")
    .select("id, entity_type, entity_id, document_type, organization_id")
    .eq("file_path", storagePath)
    .eq("entity_type", "load")
    .eq("organization_id", identity.organizationId)
    .maybeSingle();
  if (!doc || !TRIP_DOCUMENT_TYPES.has(doc.document_type)) throw new Error("Document not found.");

  const { data: dispatch } = await supabase
    .from("dispatches")
    .select("id")
    .eq("load_id", doc.entity_id)
    .eq("driver_id", identity.driverId)
    .eq("organization_id", identity.organizationId)
    .maybeSingle();
  if (!dispatch) throw new Error("Document not found.");

  const { data, error } = await supabase.storage.from("load-documents").createSignedUrl(storagePath, 300, download ? { download: true } : undefined);
  if (error || !data) throw new Error(error?.message ?? "Could not generate a download link.");
  return data.signedUrl;
}

// ---------------------------------------------------------------------------
// Profile -- safe, driver-editable fields only. Same drivers table
// column-level grants from 0014 already exclude ssn_encrypted/direct_
// deposit_*_encrypted from any client-side select; this action further
// restricts the WRITE surface to exactly phone/email/emergency contact,
// regardless of what a crafted form submission might include.
// ---------------------------------------------------------------------------
export async function updateMyDriverProfile(formData: FormData) {
  const identity = await requireIdentity();
  const supabase = createServiceRoleClient();

  const { error } = await supabase
    .from("drivers")
    .update({
      phone: emptyToNull(formData.get("phone")),
      email: emptyToNull(formData.get("email")),
      emergency_contact_name: emptyToNull(formData.get("emergency_contact_name")),
      emergency_contact_phone: emptyToNull(formData.get("emergency_contact_phone")),
    })
    .eq("id", identity.driverId)
    .eq("organization_id", identity.organizationId);
  if (error) throw new Error(error.message);

  revalidatePath("/driver-portal/profile");
}

// ---------------------------------------------------------------------------
// Phase 2I.1 (Part B4) -- driver-side messaging. Same pattern as every
// action above: resolve the session first, then verify ownership of the
// dispatch server-side (never trust a dispatchId the browser sent) --
// dispatch_messages has RLS, but it's staff-only (see 0080's own header
// comment); this service-role client bypasses it entirely, so this
// ownership check IS the real security boundary here, not a redundant
// belt-and-suspenders layer. A driver can only ever act on their OWN
// current dispatch, resolved via getCurrentDispatch() -- never an
// arbitrary dispatchId, so there is no way for one driver to address a
// message into another driver's conversation even by guessing an id.
// ---------------------------------------------------------------------------

export type DriverMessage = {
  id: string;
  senderType: "staff" | "driver";
  senderName: string | null;
  body: string;
  createdAt: string;
  readAt: string | null;
};

const MESSAGE_SELECT = "id, sender_type, sender_profile_id, body, created_at, read_at, profiles(full_name)";

function mapDriverMessage(row: { id: string; sender_type: string; sender_profile_id: string | null; body: string; created_at: string; read_at: string | null; profiles: { full_name: string } | null }): DriverMessage {
  return {
    id: row.id,
    senderType: row.sender_type as "staff" | "driver",
    // Staff sender name is resolved via the profiles join; a driver-sent
    // row has no sender_profile_id at all (it's implicitly this driver),
    // so there's nothing to join for that direction -- the Driver Portal
    // UI itself already knows "this is me."
    senderName: row.sender_type === "staff" ? (row.profiles?.full_name ?? "Dispatch") : null,
    body: row.body,
    createdAt: row.created_at,
    readAt: row.read_at,
  };
}

// Latest 50 for the driver's current dispatch -- same bounded page size as
// the staff drawer's own initial load (getDispatchDrawerData,
// board-actions.ts), so neither side can ever load more history than the
// other by accident.
export async function getMyDispatchMessages(): Promise<{ dispatchId: string | null; loadNumber: string | null; messages: DriverMessage[]; hasMore: boolean }> {
  const identity = await requireIdentity();
  const supabase = createServiceRoleClient();
  const dispatch = await getCurrentDispatch(supabase, identity.driverId);
  if (!dispatch) return { dispatchId: null, loadNumber: null, messages: [], hasMore: false };

  const { data } = await supabase.from("dispatch_messages").select(MESSAGE_SELECT).eq("dispatch_id", dispatch.id).order("created_at", { ascending: false }).limit(51);
  const rows = (data ?? []) as unknown as Parameters<typeof mapDriverMessage>[0][];
  const hasMore = rows.length > 50;
  const messages = rows.slice(0, 50).reverse().map(mapDriverMessage);

  return { dispatchId: dispatch.id, loadNumber: dispatch.load_number, messages, hasMore };
}

export async function loadMoreDriverMessages(dispatchId: string, beforeCreatedAt: string): Promise<{ messages: DriverMessage[]; hasMore: boolean }> {
  const identity = await requireIdentity();
  const supabase = createServiceRoleClient();

  const { data: dispatch } = await supabase.from("dispatches").select("id, driver_id, organization_id").eq("id", dispatchId).maybeSingle();
  if (!dispatch || dispatch.driver_id !== identity.driverId || dispatch.organization_id !== identity.organizationId) {
    throw new Error("This trip is not assigned to you.");
  }

  const { data } = await supabase.from("dispatch_messages").select(MESSAGE_SELECT).eq("dispatch_id", dispatchId).lt("created_at", beforeCreatedAt).order("created_at", { ascending: false }).limit(51);
  const rows = (data ?? []) as unknown as Parameters<typeof mapDriverMessage>[0][];
  const hasMore = rows.length > 50;
  const messages = rows.slice(0, 50).reverse().map(mapDriverMessage);

  return { messages, hasMore };
}

// Phase 2I.1A section C -- staff notification fan-out for a driver-sent
// message. Same "one row per active owner/admin/dispatcher profile"
// pattern already proven by notifyOfficeStaff() in
// evaluate-route-deviation.ts, reproduced locally here (not imported --
// that helper is server-only tracking code, this is driver-portal code;
// duplicating one small, already-battle-tested query is simpler than
// introducing a shared cross-module dependency for it). accountant/
// viewer/driver are never eligible recipients. Best-effort: a failed
// notification insert must never fail the message send itself (the
// message is already durably written by the time this runs).
const MESSAGE_PREVIEW_MAX_CHARS = 80; // + the "Load <n>: " prefix keeps the whole body near the ~100-char target (spec section C)

function truncateMessagePreview(text: string): string {
  // Plain text only -- collapse whitespace/newlines so a multi-line
  // message can't blow up the notification's line count, never HTML.
  const collapsed = text.replace(/\s+/g, " ").trim();
  return collapsed.length > MESSAGE_PREVIEW_MAX_CHARS ? `${collapsed.slice(0, MESSAGE_PREVIEW_MAX_CHARS).trimEnd()}...` : collapsed;
}

async function notifyOfficeStaffOfDriverMessage(
  supabase: ReturnType<typeof createServiceRoleClient>,
  organizationId: string,
  dispatchId: string,
  driverName: string,
  loadNumber: string,
  messageBody: string
) {
  const { data: recipients } = await supabase
    .from("profiles")
    .select("id")
    .eq("organization_id", organizationId)
    .in("role", ["owner", "admin", "dispatcher"])
    .eq("is_active", true);
  if (!recipients || recipients.length === 0) return;

  // Deliberately just name + load number + a truncated preview of the
  // driver's own words -- never rate/carrier-pay/dispatch-fee/factoring/
  // financial/private-document/compliance data, none of which this
  // function has access to in the first place (only the message body,
  // driver name, and load number are passed in).
  const rows = recipients.map((r) => ({
    organization_id: organizationId,
    profile_id: r.id,
    type: "dispatch_message" as const,
    title: `New message from ${driverName}`,
    body: `Load ${loadNumber}: ${truncateMessagePreview(messageBody)}`,
    entity_type: "dispatch" as const,
    entity_id: dispatchId,
  }));
  const { error } = await supabase.from("notifications").insert(rows);
  if (error) console.error("[driver-portal] dispatch_message notification insert failed:", error);
}

export async function sendDriverMessage(dispatchId: string, body: string) {
  const trimmed = body.trim();
  if (!trimmed) throw new Error("Message cannot be empty.");
  if (trimmed.length > 2000) throw new Error("Message is too long (2000 characters max).");

  const identity = await requireIdentity();
  const supabase = createServiceRoleClient();

  const { data: dispatch } = await supabase
    .from("dispatches")
    .select("id, load_id, driver_id, organization_id, loads(load_number)")
    .eq("id", dispatchId)
    .maybeSingle();
  if (!dispatch || dispatch.driver_id !== identity.driverId || dispatch.organization_id !== identity.organizationId) {
    throw new Error("This trip is not assigned to you.");
  }

  const { error } = await supabase.from("dispatch_messages").insert({
    organization_id: identity.organizationId,
    dispatch_id: dispatchId,
    load_id: dispatch.load_id,
    driver_id: identity.driverId,
    sender_type: "driver",
    sender_profile_id: null,
    body: trimmed,
  });
  if (error) throw new Error(error.message);

  // Best-effort fan-out, after the message itself is durably written --
  // see section L's finding (no server-side send-idempotency exists) in
  // the pre-apply report: a duplicate client resubmission would fan out a
  // duplicate notification too, same exposure the message row itself
  // already has today, not a new category of risk introduced by this
  // section.
  const loadNumber = (dispatch as unknown as { loads: { load_number: string } | null }).loads?.load_number ?? "Unknown";
  const driverName = `${identity.firstName} ${identity.lastName}`.trim();
  await notifyOfficeStaffOfDriverMessage(supabase, identity.organizationId, dispatchId, driverName, loadNumber, trimmed).catch((e) =>
    console.error("[driver-portal] dispatch_message notification fan-out failed:", e)
  );

  revalidatePath("/driver-portal/messages");
}

// Phase 2I.1A section G -- unread-count for the bottom-nav badge and
// dashboard alert. Driver/org identity comes exclusively from the
// session cookie (requireIdentity/getCurrentDispatch), exactly like every
// other action in this file -- there is no dispatchId/driverId/
// organizationId parameter here at all, so there is nothing for the
// browser to spoof. read_at on dispatch_messages stays the sole source of
// truth (never derived from `notifications`, which this driver-side path
// doesn't even read -- drivers have no profiles row / notifications
// recipient identity in the first place).
export async function getMyUnreadMessageCount(): Promise<number> {
  const identity = await requireIdentity();
  const supabase = createServiceRoleClient();
  const dispatch = await getCurrentDispatch(supabase, identity.driverId);
  if (!dispatch) return 0;

  const { count, error } = await supabase
    .from("dispatch_messages")
    .select("id", { count: "exact", head: true })
    .eq("dispatch_id", dispatch.id)
    .eq("sender_type", "staff")
    .is("read_at", null);
  if (error) {
    console.error("[driver-portal] unread message count failed:", error);
    return 0;
  }
  return count ?? 0;
}

export async function markMyMessagesRead(dispatchId: string) {
  const identity = await requireIdentity();
  const supabase = createServiceRoleClient();

  const { data: dispatch } = await supabase.from("dispatches").select("id, driver_id, organization_id").eq("id", dispatchId).maybeSingle();
  if (!dispatch || dispatch.driver_id !== identity.driverId || dispatch.organization_id !== identity.organizationId) {
    throw new Error("This trip is not assigned to you.");
  }

  // Narrow, column-specific update -- only ever read_at, only ever
  // staff-sent rows (the ones the driver could plausibly be "reading").
  await supabase.from("dispatch_messages").update({ read_at: new Date().toISOString() }).eq("dispatch_id", dispatchId).eq("sender_type", "staff").is("read_at", null);
  revalidatePath("/driver-portal/messages");
}
