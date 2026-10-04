"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireOperationalAccess } from "@/lib/billing/operational-access";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { incidentValues, incidentFileType, INCIDENT_FILE_TYPES, INCIDENT_FILE_MAX_BYTES } from "@/lib/safety/incidents";

// Safety incidents (0170). Every action returns { error } instead of
// throwing, so the person sees the real reason (a thrown server-action
// message is replaced by a generic one in production).
export type SafetyActionState = { error: string | null; saved?: boolean };

const BUCKET = "load-documents";

// The latest calendar date anywhere -- an incident "today" in any US time
// zone is never refused as being in the future.
function latestToday(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Pacific/Kiritimati", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
}

// Our own checks throw plain-language Errors; database errors arrive as
// { message } objects and are translated here, never shown raw.
function plain(err: unknown): string {
  if (err instanceof Error) return err.message || "This could not be saved. Please try again.";
  const msg = typeof err === "object" && err && "message" in err ? String((err as { message: unknown }).message) : "";
  if (/does not belong to this organization/.test(msg)) return msg;
  if (/row-level security|permission denied/i.test(msg)) return "Your role can't make this change. Ask an owner or admin.";
  if (/safety_incidents_type_check/.test(msg)) return "Choose what kind of incident this was.";
  if (/safety_incidents_cost_check/.test(msg)) return "Cost must be zero or more.";
  return "This could not be saved. Please try again.";
}

function refresh(id: string | null, v: { driver_id: string | null; truck_id: string | null }) {
  revalidatePath("/safety");
  if (id) revalidatePath(`/safety/${id}`);
  if (v.driver_id) revalidatePath(`/drivers/${v.driver_id}`);
  if (v.truck_id) revalidatePath(`/trucks/${v.truck_id}`);
}

export async function createIncident(_prev: SafetyActionState, formData: FormData): Promise<SafetyActionState> {
  let id: string;
  try {
    await requireOperationalAccess();
    const values = incidentValues(formData, latestToday());
    const supabase = await createClient();
    const organizationId = await getCurrentOrgId();
    const { data, error } = await supabase
      .from("safety_incidents")
      .insert({ organization_id: organizationId, ...values })
      .select("id")
      .single();
    if (error || !data) return { error: plain(error) };
    id = data.id as string;
    await supabase.rpc("log_activity", { p_entity_type: "safety_incident", p_entity_id: id, p_action: "created", p_changes: null, p_organization_id: organizationId });
    refresh(id, values);
  } catch (err) {
    return { error: plain(err) };
  }
  redirect(`/safety/${id}`);
}

export async function updateIncident(id: string, _prev: SafetyActionState, formData: FormData): Promise<SafetyActionState> {
  try {
    await requireOperationalAccess();
    const values = incidentValues(formData, latestToday());
    const status = String(formData.get("status") ?? "open") === "closed" ? "closed" : "open";
    const supabase = await createClient();
    const organizationId = await getCurrentOrgId();
    const { data: before } = await supabase.from("safety_incidents").select("driver_id, truck_id").eq("id", id).maybeSingle();
    const { data, error } = await supabase
      .from("safety_incidents")
      .update({ ...values, status })
      .eq("id", id)
      .select("id");
    if (error) return { error: plain(error) };
    if (!data || data.length === 0) return { error: "Your role can't make this change, or the incident no longer exists." };
    await supabase.rpc("log_activity", { p_entity_type: "safety_incident", p_entity_id: id, p_action: "updated", p_changes: null, p_organization_id: organizationId });
    refresh(id, values);
    if (before) refresh(null, before as { driver_id: string | null; truck_id: string | null });
    return { error: null, saved: true };
  } catch (err) {
    return { error: plain(err) };
  }
}

export async function deleteIncident(id: string): Promise<void> {
  await requireOperationalAccess();
  const supabase = await createClient();
  const { data: before } = await supabase.from("safety_incidents").select("driver_id, truck_id").eq("id", id).maybeSingle();
  const { data, error } = await supabase.from("safety_incidents").delete().eq("id", id).select("id");
  if (error || !data || data.length === 0) throw new Error("Only an owner or admin can delete an incident.");
  const organizationId = await getCurrentOrgId();
  await supabase.rpc("log_activity", { p_entity_type: "safety_incident", p_entity_id: id, p_action: "deleted", p_changes: null, p_organization_id: organizationId });
  if (before) refresh(null, before as { driver_id: string | null; truck_id: string | null });
  revalidatePath("/safety");
  redirect("/safety");
}

/** Adds photos / papers (police report, ticket, claim letter) to an incident. */
export async function uploadIncidentFiles(incidentId: string, _prev: SafetyActionState, formData: FormData): Promise<SafetyActionState> {
  try {
    await requireOperationalAccess();
    const files = formData.getAll("files").filter((f): f is File => f instanceof File && f.size > 0);
    if (files.length === 0) return { error: "Choose at least one photo or file." };
    if (files.length > 20) return { error: "Add up to 20 files at a time." };
    for (const f of files) {
      if (!INCIDENT_FILE_TYPES.has(f.type)) return { error: `${f.name}: use a JPG or PNG photo, or a PDF.` };
      if (f.size > INCIDENT_FILE_MAX_BYTES) return { error: `${f.name} is too large (15 MB max).` };
    }

    const supabase = await createClient();
    const organizationId = await getCurrentOrgId();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    const { data: incident } = await supabase.from("safety_incidents").select("id").eq("id", incidentId).maybeSingle();
    if (!incident) return { error: "Incident not found." };

    for (const [i, file] of files.entries()) {
      const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-100);
      const storagePath = `${organizationId}/safety/${incidentId}/${Date.now()}_${i}_${safeName}`;
      const { error: uploadError } = await supabase.storage.from(BUCKET).upload(storagePath, file, { contentType: file.type, upsert: false });
      if (uploadError) return { error: /row-level security|unauthorized/i.test(uploadError.message) ? "Your role can't add files. Ask an owner, admin or dispatcher." : `${file.name}: ${uploadError.message}` };
      const { error: insertError } = await supabase.from("documents").insert({
        organization_id: organizationId,
        entity_type: "safety_incident",
        entity_id: incidentId,
        document_type: incidentFileType(file.type),
        file_name: file.name,
        file_path: storagePath,
        file_size_bytes: file.size,
        mime_type: file.type,
        uploaded_by: user?.id ?? null,
      });
      if (insertError) {
        await supabase.storage.from(BUCKET).remove([storagePath]);
        return { error: plain(insertError) };
      }
    }
    await supabase.rpc("log_activity", { p_entity_type: "safety_incident", p_entity_id: incidentId, p_action: "files_added", p_changes: { count: files.length }, p_organization_id: organizationId });
    revalidatePath(`/safety/${incidentId}`);
    revalidatePath("/safety");
    return { error: null, saved: true };
  } catch (err) {
    return { error: plain(err) };
  }
}

/** Short-lived link to one of this incident's files. */
export async function getIncidentFileUrl(documentId: string): Promise<string | { error: string }> {
  const supabase = await createClient();
  const { data: doc } = await supabase.from("documents").select("file_path").eq("id", documentId).eq("entity_type", "safety_incident").maybeSingle();
  if (!doc) return { error: "File not found." };
  const { data, error } = await supabase.storage.from(BUCKET).createSignedUrl(doc.file_path as string, 300);
  if (error || !data) return { error: "Could not open this file." };
  return data.signedUrl;
}
