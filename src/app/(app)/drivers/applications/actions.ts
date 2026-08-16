"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";

const VALID_STATUSES = ["submitted", "under_review", "interview", "approved", "rejected", "converted"];

export async function updateApplicationStatus(applicationId: string, formData: FormData) {
  const status = String(formData.get("status") || "");
  if (!VALID_STATUSES.includes(status)) {
    throw new Error("Invalid status.");
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { error } = await supabase
    .from("driver_applications")
    .update({ status, reviewed_by: user?.id ?? null, reviewed_at: new Date().toISOString() })
    .eq("id", applicationId);
  if (error) throw new Error(error.message);

  revalidatePath(`/drivers/applications/${applicationId}`);
  revalidatePath("/drivers/applications");
}

export async function updateApplicationReviewNotes(applicationId: string, formData: FormData) {
  const reviewNotes = String(formData.get("review_notes") || "");
  const supabase = await createClient();
  const { error } = await supabase
    .from("driver_applications")
    .update({ review_notes: reviewNotes || null })
    .eq("id", applicationId);
  if (error) throw new Error(error.message);
  revalidatePath(`/drivers/applications/${applicationId}`);
}

// reveal_driver_application_pii is owner/admin-only and logs every call --
// see migration 0018. This wrapper never returns anything but the plain
// decrypted string (or null); it's never written back to a column or logged.
export async function revealApplicationSsn(applicationId: string, reason?: string): Promise<string | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reveal_driver_application_pii", {
    p_application_id: applicationId,
    p_reason: reason ?? null,
  });
  if (error) throw new Error(error.message);
  return data as string | null;
}

export async function convertApplicationToDriver(applicationId: string, formData: FormData) {
  const carrierId = String(formData.get("carrier_id") || "");
  if (!carrierId) throw new Error("Select a carrier to convert this application into a driver record.");

  const supabase = await createClient();
  const { data: driverId, error } = await supabase.rpc("convert_driver_application_to_driver", {
    p_application_id: applicationId,
    p_carrier_id: carrierId,
  });
  if (error) throw new Error(error.message);

  revalidatePath("/drivers/applications");
  redirect(`/drivers/${driverId}`);
}

// Documents live in a private Storage bucket -- generate a short-lived
// signed URL server-side rather than exposing the bucket to the client.
// Re-checks the same owner/admin/dispatcher gate the table's RLS policy
// uses, since the service-role client bypasses RLS entirely.
export async function getApplicationDocumentUrl(applicationId: string, storagePath: string): Promise<string> {
  const supabase = await createClient();
  const { data: application, error: appError } = await supabase
    .from("driver_applications")
    .select("id")
    .eq("id", applicationId)
    .maybeSingle();
  if (appError || !application) {
    throw new Error("Application not found or you don't have access to it.");
  }
  if (!storagePath.startsWith(`${applicationId}/`)) {
    throw new Error("Document does not belong to this application.");
  }

  const serviceClient = createServiceRoleClient();
  const { data, error } = await serviceClient.storage
    .from("driver-application-documents")
    .createSignedUrl(storagePath, 300);
  if (error || !data) throw new Error(error?.message ?? "Could not generate a document link.");
  return data.signedUrl;
}
