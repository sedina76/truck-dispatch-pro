"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { EMAIL_PROVIDER_CONFIGURED, sendTransactionalEmail, FRIENDLY_SEND_ERROR } from "@/lib/email/provider";
import { resolveOrgName } from "@/lib/email/resolve-entity";
import {
  computeProfileShareData,
  renderProfileSharePdf,
  buildSnapshot,
  type ProfileShareData,
} from "@/lib/profile-share/generate";

// Shareable Driver/Carrier Profile workflow (0042_profile_sharing.sql).
// Three distinct actions, matching the three dialog buttons:
//   - previewProfileShare: renders bytes on the fly, returns them as a
//     data URL for an inline <iframe>/new-tab view. NEVER writes a
//     profile_share_log row or touches storage -- a preview is not a
//     share (spec: only Download/Email represent an actual hand-off).
//   - generateProfileShare: the one real "commit" step. Renders the PDF,
//     uploads it to the private shared-profiles bucket, and inserts the
//     immutable profile_share_log row (status GENERATED) with a frozen
//     snapshot. Used by both the Download button and as the first step of
//     Email.
//   - sendProfileShareGeneratedEmail: attempts to actually send an
//     already-generated share. With no provider configured (always true
//     today) this updates the log row to BLOCKED and returns the same
//     honest "Email provider not configured." error the toolbar's
//     /api/email/send route gives -- never fakes success.

type ProfileSelection = {
  loadId: string;
  driverId: string | null;
  carrierId: string | null;
  documentIds: string[];
  recipientEmail: string;
  recipientPartyType: "broker" | "customer" | null;
};

function resolveProfileType(driverId: string | null, carrierId: string | null): "driver" | "carrier" | "combined" {
  if (driverId && carrierId) return "combined";
  if (driverId) return "driver";
  return "carrier";
}

export async function previewProfileShare(selection: ProfileSelection): Promise<string> {
  if (!selection.driverId && !selection.carrierId) throw new Error("Select at least one profile to preview.");
  const data = await computeProfileShareData({
    loadId: selection.loadId,
    includeDriverId: selection.driverId,
    includeCarrierId: selection.carrierId,
    includeDocumentIds: [], // preview never needs to resolve attachment file names
  });
  const bytes = await renderProfileSharePdf(data);
  return `data:application/pdf;base64,${Buffer.from(bytes).toString("base64")}`;
}

export async function generateProfileShare(
  selection: ProfileSelection
): Promise<{ shareId: string; downloadUrl: string; snapshot: ReturnType<typeof buildSnapshot> }> {
  if (!selection.driverId && !selection.carrierId) throw new Error("Select at least one profile to share.");
  if (!selection.recipientEmail) throw new Error("A recipient email is required.");

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const data: ProfileShareData = await computeProfileShareData({
    loadId: selection.loadId,
    includeDriverId: selection.driverId,
    includeCarrierId: selection.carrierId,
    includeDocumentIds: selection.documentIds,
  });

  const bytes = await renderProfileSharePdf(data);
  const snapshot = buildSnapshot(data);

  // Insert first (without storage_path) to get a real id for the storage
  // path -- the guard triggers (guard_profile_share_org, same-org +
  // document-safety checks) run on THIS insert, so an invalid/cross-org/
  // unauthorized document selection is rejected before anything is ever
  // written to storage.
  const { data: inserted, error: insertError } = await supabase
    .from("profile_share_log")
    .insert({
      organization_id: organizationId,
      load_id: selection.loadId,
      driver_id: selection.driverId,
      carrier_id: selection.carrierId,
      profile_type: resolveProfileType(selection.driverId, selection.carrierId),
      recipient_email: selection.recipientEmail,
      recipient_party_type: selection.recipientPartyType,
      document_ids_included: selection.documentIds,
      snapshot,
      status: "GENERATED",
      generated_by: user?.id ?? null,
    })
    .select("id")
    .single();
  if (insertError) throw new Error(insertError.message);

  const storagePath = `${organizationId}/${selection.loadId}/${inserted.id}/profile.pdf`;
  const { error: uploadError } = await supabase.storage
    .from("shared-profiles")
    .upload(storagePath, bytes, { contentType: "application/pdf", upsert: false });
  if (uploadError) {
    // Roll the log row's intent back by marking it FAILED rather than
    // leaving a GENERATED row with no file behind it -- storage_path stays
    // null, which the history UI already treats as "no PDF available".
    await supabase.from("profile_share_log").update({ status: "FAILED", error: uploadError.message }).eq("id", inserted.id);
    throw new Error("Could not store the generated profile PDF: " + uploadError.message);
  }

  // storage_path is the one field guard_profile_share_immutable does NOT
  // freeze on the very first update from GENERATED (see the trigger --
  // it only blocks changes once status has already left GENERATED, and
  // this update leaves status at GENERATED), so recording it here is safe.
  await supabase.from("profile_share_log").update({ storage_path: storagePath }).eq("id", inserted.id);

  const { data: signed } = await supabase.storage.from("shared-profiles").createSignedUrl(storagePath, 300);

  revalidatePath(`/loads/${selection.loadId}`);
  return { shareId: inserted.id, downloadUrl: signed?.signedUrl ?? "", snapshot };
}

// Only ever called with a shareId that generateProfileShare just returned
// in the same user action -- there is no separate "resend" path in this
// pass, matching "Do not send anything automatically without user action."
export async function sendProfileShareGeneratedEmail(
  shareId: string,
  loadId: string,
  subject: string,
  message: string
): Promise<{ ok: boolean; error?: string }> {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // Re-verify the share belongs to the caller's org and is still in
  // GENERATED state under RLS before doing anything -- mirrors the
  // cross-org re-verification fix applied to /api/email/send earlier this
  // session (Test 15).
  const { data: share } = await supabase
    .from("profile_share_log")
    .select("id, status, recipient_email, storage_path")
    .eq("id", shareId)
    .maybeSingle();
  if (!share) return { ok: false, error: "Share record not found." };

  async function logAttempt(status: "sent" | "failed", error: string | null, providerMessageId: string | null) {
    await supabase.from("email_send_log").insert({
      organization_id: organizationId,
      entity_type: "profile_share",
      entity_id: shareId,
      recipient: share!.recipient_email,
      subject,
      attachment_type: "profile_share_pdf",
      status,
      error,
      sent_at: status === "sent" ? new Date().toISOString() : null,
      provider_message_id: providerMessageId,
      sent_by: user?.id ?? null,
    });
  }

  if (!EMAIL_PROVIDER_CONFIGURED) {
    const error = "Email provider not configured.";
    await supabase.from("profile_share_log").update({ status: "BLOCKED", error }).eq("id", shareId);
    await supabase.from("email_send_log").insert({
      organization_id: organizationId,
      entity_type: "profile_share",
      entity_id: shareId,
      recipient: share.recipient_email,
      subject,
      attachment_type: null,
      status: "blocked",
      error,
      sent_by: user?.id ?? null,
    });
    revalidatePath(`/loads/${loadId}`);
    return { ok: false, error };
  }

  if (!share.storage_path) {
    const error = "This share has no generated PDF on file.";
    await supabase.from("profile_share_log").update({ status: "FAILED", error }).eq("id", shareId);
    await logAttempt("failed", error, null);
    revalidatePath(`/loads/${loadId}`);
    return { ok: false, error };
  }

  const { data: fileData, error: downloadError } = await supabase.storage.from("shared-profiles").download(share.storage_path);
  if (downloadError || !fileData) {
    const error = "Could not read the generated profile PDF.";
    await supabase.from("profile_share_log").update({ status: "FAILED", error }).eq("id", shareId);
    await logAttempt("failed", error, null);
    revalidatePath(`/loads/${loadId}`);
    return { ok: false, error: FRIENDLY_SEND_ERROR };
  }

  const sendResult = await sendTransactionalEmail({
    to: share.recipient_email,
    subject,
    text: message,
    organizationName: await resolveOrgName(supabase),
    heading: subject,
    attachments: [{ filename: "driver-carrier-profile.pdf", content: Buffer.from(await fileData.arrayBuffer()) }],
  });

  if (!sendResult.ok) {
    await supabase.from("profile_share_log").update({ status: "FAILED", error: sendResult.error }).eq("id", shareId);
    await logAttempt("failed", sendResult.error, null);
    revalidatePath(`/loads/${loadId}`);
    return { ok: false, error: FRIENDLY_SEND_ERROR };
  }

  await supabase.from("profile_share_log").update({ status: "SENT", sent_at: new Date().toISOString(), error: null, sent_by: user?.id ?? null }).eq("id", shareId);
  await logAttempt("sent", null, sendResult.providerMessageId);
  revalidatePath(`/loads/${loadId}`);
  return { ok: true };
}

export async function getProfileShareSignedUrl(storagePath: string, download: boolean): Promise<string> {
  const supabase = await createClient();
  const { data, error } = await supabase.storage
    .from("shared-profiles")
    .createSignedUrl(storagePath, 300, download ? { download: true } : undefined);
  if (error || !data) throw new Error(error?.message ?? "Could not generate a download link.");
  return data.signedUrl;
}
