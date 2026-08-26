"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createHash } from "node:crypto";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentOrgId } from "@/lib/actions/records";
import { emptyToNull } from "@/lib/utils/form";
import { requireRole } from "@/lib/auth/require-role";
import { renderBrokerPacket, type SourceFile } from "@/lib/broker-packets/generate";
import { runBoundedStorageUpload, storageUploadErrorStatus, type StorageObjectConfirmation, type StorageUploadErrorLike } from "@/lib/broker-packets/storage-retry";
import { BROKER_PACKET_BUCKET, MAX_EMAIL_ATTACHMENT_BYTES, BROKER_PACKET_SOURCE_BUCKETS, brokerPacketStoragePath, type BrokerPacketItemRow, type BrokerPacketRow } from "@/lib/broker-packets/types";
import { brokerPacketFilename } from "@/lib/broker-packets/filename";
import { resolveEmailAuthorizationContext } from "@/lib/email/authorization";
import { sendTenantEmail } from "@/lib/email/send-pipeline";

// Draft creation, item selection, reservation, generation (2M.3), and
// (2M.4) send. Every action EXCEPT sendBrokerPacket is invoked from a
// plain <form action={...}>, so those follow this file family's existing
// throw-based convention (see ../actions.ts's saveBrokerContact/
// deleteBrokerContact) rather than returning a result object -- a raw
// form action prop must return void | Promise<void>. sendBrokerPacket is
// driven by a controlled client component instead (mirroring
// carrier-setup-packages/actions.ts's sendSetupPackage exactly), so it
// returns an ActionResult the UI can render inline without a page
// navigation.
type ActionResult<T = undefined> = T extends undefined ? { ok: true } | { ok: false; error: string } : { ok: true; data: T } | { ok: false; error: string };

export async function createBrokerPacketDraft(brokerId: string, formData: FormData) {
  await requireRole(["owner", "admin", "dispatcher"]);
  const supabase = await createClient();
  const carrierId = emptyToNull(formData.get("carrier_id"));
  const { data, error } = await supabase.rpc("create_broker_packet_draft", { p_broker_id: brokerId, p_carrier_id: carrierId });
  if (error) throw new Error(error.message);
  revalidatePath(`/brokers/${brokerId}?tab=broker-packets`);
  redirect(`/brokers/${brokerId}/packets/${data}`);
}

export async function addBrokerPacketItem(brokerId: string, packetId: string, formData: FormData) {
  await requireRole(["owner", "admin", "dispatcher"]);
  const documentId = String(formData.get("document_id") || "");
  if (!documentId) throw new Error("Select a document to add.");
  const supabase = await createClient();
  const { error } = await supabase.rpc("add_broker_packet_item", { p_packet_id: packetId, p_document_id: documentId });
  if (error) throw new Error(error.message);
  revalidatePath(`/brokers/${brokerId}/packets/${packetId}`);
}

export async function removeBrokerPacketItem(brokerId: string, packetId: string, itemId: string) {
  await requireRole(["owner", "admin", "dispatcher"]);
  const supabase = await createClient();
  const { error } = await supabase.rpc("remove_broker_packet_item", { p_packet_id: packetId, p_item_id: itemId });
  if (error) throw new Error(error.message);
  revalidatePath(`/brokers/${brokerId}/packets/${packetId}`);
}

export async function moveBrokerPacketItem(brokerId: string, packetId: string, itemIds: string[], itemId: string, direction: -1 | 1) {
  await requireRole(["owner", "admin", "dispatcher"]);
  const index = itemIds.indexOf(itemId);
  const swapWith = index + direction;
  if (index < 0 || swapWith < 0 || swapWith >= itemIds.length) return;
  const reordered = [...itemIds];
  [reordered[index], reordered[swapWith]] = [reordered[swapWith], reordered[index]];
  const supabase = await createClient();
  const { error } = await supabase.rpc("reorder_broker_packet_items", { p_packet_id: packetId, p_item_ids: reordered });
  if (error) throw new Error(error.message);
  revalidatePath(`/brokers/${brokerId}/packets/${packetId}`);
}

// Phase 2M.2A repair -- replaces the previous one-form-per-document-type,
// one-Save-button-per-row layout (7 separate <form>s, each independently
// posting and each independently redirecting/soft-refreshing) with a
// single bulk save. That old shape had two real problems, not just UX
// friction: (1) revalidatePath targeted "/brokers/{id}/packets", a route
// with no page.tsx at all (the real page is
// "/brokers/{id}/packets/{packetId}") -- effectively a no-op; (2) each
// checkbox used defaultChecked (uncontrolled) driven by server data --
// React deliberately never re-applies defaultChecked to an
// already-mounted input on a subsequent render, so even a fully
// successful save could never visibly reflect back into the checkbox
// after the Next.js server-action "soft refresh" this button triggers,
// which reconciles the existing DOM tree rather than remounting it. The
// data was very likely persisting correctly the whole time -- the UI
// simply never showed it. Fixed by moving to ONE controlled, client-side
// checklist (requirements-checklist.tsx) that owns its own state and this
// one bulk action, called via useTransition from a real button click, so
// the visible state is exactly what was just saved rather than depending
// on a prop update reaching an uncontrolled input.
export async function setBrokerPacketRequirements(
  brokerId: string,
  requirements: { document_type: string; is_required: boolean }[]
): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();
  const { data: role } = await supabase.rpc("current_role");
  if (!["owner", "admin", "dispatcher"].includes(String(role))) return { ok: false, error: "You do not have permission to edit broker packet requirements." };

  const { data: broker } = await supabase.from("brokers").select("organization_id").eq("id", brokerId).maybeSingle();
  if (!broker) return { ok: false, error: "Broker not found." };
  if (requirements.length === 0) return { ok: true };

  // One bulk upsert (all rows in a single round trip), not N sequential
  // ones -- Section M performance concern applies to the write side too,
  // not just reads.
  const { error } = await supabase
    .from("broker_packet_requirements")
    .upsert(
      requirements.map((r) => ({ broker_id: brokerId, organization_id: broker.organization_id, document_type: r.document_type, is_required: r.is_required })),
      { onConflict: "broker_id,document_type" }
    );
  if (error) return { ok: false, error: error.message };

  revalidatePath(`/brokers/${brokerId}?tab=broker-packets`);
  return { ok: true };
}

function safeFailureStage(message: string) {
  if (/download|source|document/i.test(message)) return "Broker packet generation failed during source validation.";
  if (/pdf|page|image|merge/i.test(message)) return "Broker packet generation failed during PDF composition.";
  if (/upload|storage/i.test(message)) return "Broker packet generation failed during secure storage.";
  return "Broker packet generation failed.";
}

const STORAGE_UPLOAD_RETRY_DELAY_MS = 250;

function logStorageUploadError(params: {
  error: StorageUploadErrorLike;
  attempt: number;
  packetId: string;
  organizationId: string;
  brokerId: string;
  packetVersion: number;
  generatedByteLength: number;
  objectPath: string;
}) {
  console.error("[broker-packet-upload]", {
    operation: "broker_packet_upload",
    attempt: params.attempt,
    packetId: params.packetId,
    organizationId: params.organizationId,
    brokerId: params.brokerId,
    packetVersion: params.packetVersion,
    generatedByteLength: params.generatedByteLength,
    bucket: BROKER_PACKET_BUCKET,
    objectPath: params.objectPath,
    errorName: params.error.name ?? null,
    errorMessage: params.error.message ?? null,
    status: storageUploadErrorStatus(params.error),
    statusCode: params.error.statusCode ?? null,
    code: params.error.code ?? null,
  });
}

async function confirmGeneratedObject(
  service: ReturnType<typeof createServiceRoleClient>,
  objectPath: string,
  expectedBytes: number
): Promise<"matching" | "absent" | "mismatch" | "unknown"> {
  const slash = objectPath.lastIndexOf("/");
  const folder = objectPath.slice(0, slash);
  const filename = objectPath.slice(slash + 1);
  const { data, error } = await service.storage.from(BROKER_PACKET_BUCKET).list(folder, { limit: 10, search: filename });
  if (error) return "unknown";
  const object = data?.find((entry) => entry.name === filename);
  if (!object) return "absent";
  const size = Number(object.metadata?.size);
  return Number.isFinite(size) && size === expectedBytes ? "matching" : "mismatch";
}

async function uploadGeneratedPacket(params: {
  service: ReturnType<typeof createServiceRoleClient>;
  objectPath: string;
  bytes: Uint8Array;
  packetId: string;
  organizationId: string;
  brokerId: string;
  packetVersion: number;
}): Promise<boolean> {
  const result = await runBoundedStorageUpload({
    upload: async () => {
      const { error } = await params.service.storage.from(BROKER_PACKET_BUCKET).upload(params.objectPath, params.bytes, { contentType: "application/pdf", upsert: false });
      return error as (typeof error & StorageUploadErrorLike) | null;
    },
    confirmObject: () => confirmGeneratedObject(params.service, params.objectPath, params.bytes.length) as Promise<StorageObjectConfirmation>,
    delay: () => new Promise((resolve) => setTimeout(resolve, STORAGE_UPLOAD_RETRY_DELAY_MS)),
    onAttemptError: (error, attempt) => logStorageUploadError({ ...params, error, attempt, generatedByteLength: params.bytes.length }),
    onRetrySucceeded: () => console.info("[broker-packet-upload]", { operation: "broker_packet_upload_retry_succeeded", packetId: params.packetId, packetVersion: params.packetVersion }),
    onConfirmedAfterResponseFailure: (attempt) => console.info("[broker-packet-upload]", { operation: "broker_packet_upload_confirmed_after_response_failure", packetId: params.packetId, packetVersion: params.packetVersion, attempt }),
  });
  return result.ok;
}

// Full generation workflow (2M.3): reserve (if still draft; a packet
// already sitting at 'generating' from an interrupted previous attempt is
// resumed in place rather than re-reserved -- reserve_broker_packet() is
// draft-only by design, so this is the only legitimate retry path) ->
// download and verify every source document's exact bytes -> render the
// PDF entirely from the frozen snapshots and those bytes -> compute the
// final SHA-256 over the exact saved bytes -> upload those exact bytes to
// private storage at the deterministic path -> finalize. Any failure past
// the point the packet is confirmably 'generating' calls fail_broker_packet()
// with a safe, bounded, non-sensitive reason and best-effort removes a
// just-uploaded (never-finalized) object -- an already-finalized/historical
// object is never touched by this function.
export async function generateBrokerPacket(brokerId: string, packetId: string) {
  await requireRole(["owner", "admin", "dispatcher"]);
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  const { data: current } = await supabase.from("broker_packets").select("status").eq("id", packetId).eq("broker_id", brokerId).maybeSingle();
  if (!current) throw new Error("Broker packet not found.");
  if (!["draft", "generating"].includes(current.status)) {
    throw new Error(`This broker packet is already ${current.status} and cannot be generated again.`);
  }

  let reachedGenerating = current.status === "generating";
  let storagePath: string | null = null;
  try {
    if (!reachedGenerating) {
      const { error: reserveError } = await supabase.rpc("reserve_broker_packet", { p_packet_id: packetId });
      if (reserveError) throw new Error(reserveError.message);
      reachedGenerating = true;
    }

    const [{ data: packetData }, { data: itemData }] = await Promise.all([
      supabase.from("broker_packets").select("*").eq("id", packetId).single(),
      supabase.from("broker_packet_items").select("*").eq("packet_id", packetId).order("display_order"),
    ]);
    if (!packetData || !itemData?.length) throw new Error("Reserved broker packet data could not be read.");
    const pkg = packetData as unknown as BrokerPacketRow;
    const items = itemData as unknown as BrokerPacketItemRow[];
    if (pkg.organization_id !== organizationId || pkg.broker_id !== brokerId) throw new Error("Reserved broker packet ownership is invalid.");
    if (pkg.status !== "generating" || pkg.version == null || !pkg.organization_snapshot || !pkg.broker_snapshot) {
      throw new Error("Broker packet is not in a generating state.");
    }

    const service = createServiceRoleClient();
    const sources: SourceFile[] = [];
    for (const item of items) {
      if (!BROKER_PACKET_SOURCE_BUCKETS.has(item.source_storage_bucket)) throw new Error("A source document has an invalid storage location.");
      const { data, error } = await service.storage.from(item.source_storage_bucket).download(item.source_storage_path);
      if (error || !data) throw new Error("A selected source document could not be downloaded.");
      const bytes = new Uint8Array(await data.arrayBuffer());
      if (item.source_file_size_bytes !== bytes.length) throw new Error("A source document changed after broker packet reservation.");
      sources.push({ item, bytes });
    }

    const generated = await renderBrokerPacket({
      version: pkg.version,
      generatedAt: new Date(),
      organization: pkg.organization_snapshot,
      broker: pkg.broker_snapshot,
      carrier: pkg.carrier_snapshot,
      sources,
    });

    storagePath = brokerPacketStoragePath(pkg);
    const finalHash = createHash("sha256").update(generated.bytes).digest("hex");
    const uploaded = await uploadGeneratedPacket({ service, objectPath: storagePath, bytes: generated.bytes, packetId: pkg.id, organizationId, brokerId, packetVersion: pkg.version });
    if (!uploaded) throw new Error("The generated broker packet could not be uploaded to secure storage.");

    const { error: finalizeError } = await service.rpc("finalize_broker_packet", {
      p_packet_id: packetId,
      p_storage_path: storagePath,
      p_file_size_bytes: generated.bytes.length,
      p_page_count: generated.pageCount,
      p_generated_pdf_sha256: finalHash,
      p_item_results: generated.itemResults,
    });
    if (finalizeError) throw new Error("The generated broker packet could not be finalized.");
  } catch (error) {
    const message = error instanceof Error ? error.message : "Broker packet generation failed.";
    if (reachedGenerating) {
      const service = createServiceRoleClient();
      // Only ever removes the object THIS attempt just uploaded and that
      // never got finalized -- an already-finalized/historical artifact is
      // never reachable from this path (finalize_broker_packet() already
      // succeeded by the time storagePath could belong to one).
      if (storagePath) await service.storage.from(BROKER_PACKET_BUCKET).remove([storagePath]);
      await service.rpc("fail_broker_packet", { p_packet_id: packetId, p_failure_reason: safeFailureStage(message) });
    }
    revalidatePath(`/brokers/${brokerId}/packets/${packetId}`);
    throw new Error(message);
  }
  revalidatePath(`/brokers/${brokerId}/packets/${packetId}`);
  revalidatePath(`/brokers/${brokerId}?tab=broker-packets`);
}

export async function deleteBrokerPacketDraft(brokerId: string, packetId: string) {
  await requireRole(["owner", "admin", "dispatcher"]);
  const supabase = await createClient();
  const { error } = await supabase.rpc("delete_broker_packet_draft", { p_packet_id: packetId });
  if (error) throw new Error(error.message);
  revalidatePath(`/brokers/${brokerId}?tab=broker-packets`);
  redirect(`/brokers/${brokerId}?tab=broker-packets`);
}

export async function voidBrokerPacket(brokerId: string, packetId: string, formData: FormData) {
  await requireRole(["owner", "admin"]);
  const supabase = await createClient();
  const reason = String(formData.get("reason") || "");
  const { error } = await supabase.rpc("void_broker_packet", { p_packet_id: packetId, p_reason: reason });
  if (error) throw new Error(error.message);
  revalidatePath(`/brokers/${brokerId}/packets/${packetId}`);
}

// 2M.4 -- Broker Packet email delivery. Sends ONLY the already-finalized
// stored artifact: never regenerates the PDF, never trusts a client-
// supplied storage path/hash/bytes. Mirrors carrier-setup-packages/
// actions.ts's sendSetupPackage() exactly: same artifact re-derivation +
// SHA-256/size fail-closed check, same sendTenantEmail() pipeline (the
// one authoritative send path in this app -- see send-pipeline.ts), same
// mark-sent-only-after-confirmed-provider-acceptance ordering. DB-level
// authorization (mark_broker_packet_sent(), 0095) is owner/admin/
// dispatcher -- this app-layer check exists only as defense-in-depth,
// never as a bypass of it.
export async function sendBrokerPacket(
  brokerId: string,
  packetId: string,
  input: { to: string; subject: string; message: string; explicitResend: boolean }
): Promise<ActionResult> {
  try {
    // Deliberately NOT requireRole() here: that helper redirect()s for a
    // disallowed role, which is correct for a page-level guard but would
    // break out of this function's try/catch (and this ActionResult
    // contract) for driver/anonymous. Mirrors carrier-setup-packages/
    // actions.ts's authenticatedContext() pattern instead -- a plain role
    // read + an ActionResult error, exactly like every other check in
    // this function.
    const supabase = await createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (!user) return { ok: false, error: "Not authenticated." };
    const { data: role } = await supabase.rpc("current_role");
    if (!["owner", "admin", "dispatcher"].includes(String(role))) return { ok: false, error: "You do not have permission to send broker packets." };
    const organizationId = await getCurrentOrgId();

    // Independently re-load the packet server-side -- every value used
    // below comes from this row, never from the browser.
    const { data } = await supabase.from("broker_packets").select("*").eq("id", packetId).eq("broker_id", brokerId).maybeSingle();
    if (!data || data.organization_id !== organizationId || !["generated", "sent"].includes(data.status)) {
      return { ok: false, error: "Generated broker packet not found." };
    }
    const pkg = data as unknown as BrokerPacketRow;
    if (!pkg.generated_storage_path || !pkg.generated_pdf_sha256 || !pkg.generated_file_size_bytes || !pkg.generated_at || pkg.version == null) {
      return { ok: false, error: "This broker packet has no generated PDF." };
    }

    // Artifact integrity, fail-closed (2M.4 section 5): independently
    // derive the expected deterministic path, download the exact bytes
    // from the trusted server-side path (never the client), and require
    // BOTH the hash and the byte length to match the frozen metadata
    // before any email is ever prepared.
    const expected = brokerPacketStoragePath(pkg);
    if (pkg.generated_storage_path !== expected) return { ok: false, error: "Broker packet storage path is invalid." };
    const service = createServiceRoleClient();
    const { data: file, error: fileError } = await service.storage.from(BROKER_PACKET_BUCKET).download(expected);
    if (fileError || !file) return { ok: false, error: "Could not read the finalized broker packet PDF." };
    const attachmentBytes = Buffer.from(await file.arrayBuffer());
    const attachmentHash = createHash("sha256").update(attachmentBytes).digest("hex");
    if (attachmentBytes.length !== pkg.generated_file_size_bytes || attachmentHash !== pkg.generated_pdf_sha256) {
      // Never leak the actual hash/path/size values to the client here --
      // this is exactly the tamper/corruption case section 5 requires
      // failing closed on. Full detail stays server-side only.
      console.error("[broker-packet-send] artifact integrity mismatch", { packetId: pkg.id, organizationId });
      return { ok: false, error: "The stored broker packet no longer matches its finalized metadata. Contact support before sending." };
    }
    if (attachmentBytes.length > MAX_EMAIL_ATTACHMENT_BYTES) {
      return { ok: false, error: "Broker packet is too large to email. Download the PDF and send it using your preferred delivery method." };
    }

    const to = String(input.to || "").trim();
    if (!to) return { ok: false, error: "A recipient email address is required." };
    const subject = String(input.subject || "").trim();
    if (!subject) return { ok: false, error: "A subject is required." };
    const message = String(input.message || "").trim();
    if (!message) return { ok: false, error: "A message is required." };

    const auth = await resolveEmailAuthorizationContext();
    if (!auth.ok) return { ok: false, error: auth.error };

    const brokerLegalName = pkg.broker_snapshot?.legal_name || "Broker";
    const filename = brokerPacketFilename(brokerLegalName, (pkg.generated_at ?? new Date().toISOString()).slice(0, 10), pkg.version);

    const result = await sendTenantEmail({
      authContext: auth.context,
      emailPurpose: "broker_packet",
      to: [to],
      subject,
      text: message,
      attachments: [{ filename, content: attachmentBytes }],
      entityType: "broker_packet",
      entityId: pkg.id,
      entities: { brokerId: pkg.broker_id, brokerPacketId: pkg.id },
      sentBy: user?.id ?? null,
      // Baked-in version (spec pattern from sendSetupPackage): a new
      // packet version is always a fresh idempotency key, so email
      // history never conflates one version's send with another's.
      idempotencyBaseKey: `broker_packet_sent:${pkg.id}:v${pkg.version}`,
      isExplicitResend: input.explicitResend,
      metadata: { packet_version: pkg.version, document_count: pkg.document_count },
    });
    if (!result.ok) return { ok: false, error: result.error };

    // generated -> sent ONLY after confirmed provider acceptance (result.ok
    // is only true once sendTenantEmail has durably recorded a provider
    // message id -- see send-pipeline.ts). mark_broker_packet_sent()
    // itself requires a 'sent' email_send_log row scoped to this exact
    // packet id, so a mismatched/missing ledger row is a hard failure
    // here, never silently ignored.
    const { error: markError } = await supabase.rpc("mark_broker_packet_sent", { p_packet_id: pkg.id, p_email_send_log_id: result.emailSendLogId });
    if (markError) return { ok: false, error: "Email sent, but broker packet history could not be updated. Review Email History before retrying." };

    revalidatePath(`/brokers/${brokerId}/packets/${packetId}`);
    return { ok: true };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : "Could not send the broker packet." };
  }
}
