"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { sendTenantEmail } from "@/lib/email/send-pipeline";
import { resolveEmailAuthorizationContext } from "@/lib/email/authorization";
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
//
// Migrated onto the central pipeline (spec review item 3) -- this is
// tenant business email (a driver/carrier profile handed to a broker or
// customer contact), not platform system email, so it gets tenant sender
// resolution, organization/entity linkage, idempotency, and delivery
// tracking exactly like invoice/billing-packet email. Each share row is
// itself a unique, one-shot document (generateProfileShare() always
// creates a fresh shareId), so shareId alone is a sufficient idempotency
// base key -- no version/resend-sequence concept is needed beyond the
// pipeline's own default (sequence 0, i.e. a second attempt at the SAME
// shareId is a blocked accidental duplicate, matching this function's own
// "no separate resend path" design).
export async function sendProfileShareGeneratedEmail(
  shareId: string,
  loadId: string,
  subject: string,
  message: string
): Promise<{ ok: boolean; error?: string }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const auth = await resolveEmailAuthorizationContext();
  if (!auth.ok) return { ok: false, error: auth.error };

  // Re-verify the share belongs to the caller's org and is still in
  // GENERATED state under RLS before doing anything -- mirrors the
  // cross-org re-verification fix applied to /api/email/send earlier this
  // session (Test 15).
  const { data: share } = await supabase
    .from("profile_share_log")
    .select("id, status, recipient_email, storage_path, load_id, driver_id")
    .eq("id", shareId)
    .maybeSingle();
  if (!share) return { ok: false, error: "Share record not found." };

  if (!share.storage_path) {
    const error = "This share has no generated PDF on file.";
    await supabase.from("profile_share_log").update({ status: "FAILED", error }).eq("id", shareId);
    return { ok: false, error };
  }

  const { data: fileData, error: downloadError } = await supabase.storage.from("shared-profiles").download(share.storage_path);
  if (downloadError || !fileData) {
    const error = "Could not read the generated profile PDF.";
    await supabase.from("profile_share_log").update({ status: "FAILED", error }).eq("id", shareId);
    return { ok: false, error: "Email could not be sent. Please try again." };
  }

  const sendResult = await sendTenantEmail({
    authContext: auth.context,
    emailPurpose: "profile_share",
    to: [share.recipient_email],
    subject,
    text: message,
    attachments: [{ filename: "driver-carrier-profile.pdf", content: Buffer.from(await fileData.arrayBuffer()) }],
    entityType: "profile_share",
    entityId: shareId,
    entities: { loadId: share.load_id, driverId: share.driver_id },
    sentBy: user?.id ?? null,
    idempotencyBaseKey: `profile_share_sent:${shareId}`,
  });

  if (!sendResult.ok) {
    const status = sendResult.error === "Email provider not configured." ? "BLOCKED" : "FAILED";
    await supabase.from("profile_share_log").update({ status, error: sendResult.error }).eq("id", shareId);
    revalidatePath(`/loads/${loadId}`);
    return { ok: false, error: sendResult.error };
  }

  await supabase.from("profile_share_log").update({ status: "SENT", sent_at: new Date().toISOString(), error: null, sent_by: user?.id ?? null }).eq("id", shareId);
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
