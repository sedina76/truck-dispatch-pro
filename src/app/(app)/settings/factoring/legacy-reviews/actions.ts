"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

const PATH = "/settings/factoring/legacy-reviews";
type Result = { ok: true } | { ok: false; error: string };
const uuid = (v: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const reasonOk = (v: string) => v.trim().length >= 12 && v.trim().length <= 500;
const failure = (error: string): Result => ({ ok: false, error });

async function owner() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return null;
  const { data: profile } = await supabase.from("profiles").select("organization_id, role").eq("id", user.id).maybeSingle();
  if (!profile || !["owner", "admin"].includes(profile.role)) return null;
  return { supabase, userId: user.id, orgId: profile.organization_id };
}

async function target(auth: NonNullable<Awaited<ReturnType<typeof owner>>>, reviewId: string) {
  const { data: review } = await auth.supabase.from("carrier_inference_review_0155")
    .select("id, relationship_id, classification, decision_status, prior_carrier_id, exception_record_id, decision_evidence_ref, updated_at")
    .eq("id", reviewId).eq("organization_id", auth.orgId).maybeSingle();
  if (!review || review.classification !== "unsafe_assigned" || review.prior_carrier_id == null) return null;
  const { data: relationship } = await auth.supabase.from("factoring_relationships")
    .select("id, is_active, is_default, carrier_id, updated_at")
    .eq("id", review.relationship_id).eq("organization_id", auth.orgId).maybeSingle();
  if (!relationship || relationship.carrier_id !== review.prior_carrier_id) return null;
  return { review, relationship };
}

export async function deactivateReviewedRelationship(reviewId: string, expectedUpdatedAt: string, reason: string, key: string): Promise<Result> {
  if (!uuid(reviewId) || !uuid(key) || !Number.isFinite(Date.parse(expectedUpdatedAt)) || !reasonOk(reason))
    return failure("Enter a reason of 12–500 characters and refresh the review before continuing.");
  const auth = await owner();
  if (!auth) return failure("Only an owner or admin may retire a factoring relationship.");
  const record = await target(auth, reviewId);
  if (!record || record.review.decision_status !== "pending") return failure("Review unavailable or already decided.");
  if (!record.relationship.is_active || record.relationship.is_default) return failure("The relationship must be active and non-default. Refresh the review.");
  if (record.relationship.updated_at !== expectedUpdatedAt) return failure("The relationship changed. Refresh before continuing.");
  const { data, error } = await auth.supabase.rpc("deactivate_factoring_relationship", {
    p_relationship_id: record.relationship.id,
    p_reason: reason.trim(),
    p_expected_updated_at: expectedUpdatedAt,
    p_idempotency_key: key,
    p_coordinated: false,
  });
  if (error || data?.success !== true) return failure(String(data?.message ?? "The guarded deactivation was refused. Refresh and review the relationship."));
  revalidatePath(PATH);
  revalidatePath("/settings/factoring");
  return { ok: true };
}

export async function recordReviewedRetirement(reviewId: string, expectedUpdatedAt: string, reason: string, evidenceRef: string, key: string): Promise<Result> {
  if (!uuid(reviewId) || !uuid(key) || !Number.isFinite(Date.parse(expectedUpdatedAt)) || !reasonOk(reason) ||
      evidenceRef.trim().length < 8 || evidenceRef.trim().length > 300)
    return failure("Enter a reason (12–500 characters) and evidence reference (8–300 characters).");
  const auth = await owner();
  if (!auth) return failure("Only an owner or admin may record this decision.");
  const record = await target(auth, reviewId);
  if (!record || record.review.decision_status !== "pending") return failure("Review unavailable or already decided.");
  if (record.relationship.is_active || record.relationship.is_default) return failure("Deactivate this relationship before recording retirement.");
  if (record.review.updated_at !== expectedUpdatedAt) return failure("The review changed. Refresh before continuing.");
  const { data, error } = await auth.supabase.rpc("decide_carrier_inference_review", {
    p_review_id: reviewId, p_decision: "retire", p_reason: reason.trim(),
    p_evidence_ref: evidenceRef.trim(), p_expected_updated_at: expectedUpdatedAt,
    p_idempotency_key: key, p_carrier_id: null,
  });
  if (error || data?.success !== true) return failure(String(data?.message ?? "The retirement decision was refused. Refresh and review the record."));
  revalidatePath(PATH);
  return { ok: true };
}

export async function resolveRetiredRelationshipException(reviewId: string, note: string): Promise<Result> {
  if (!uuid(reviewId) || !reasonOk(note)) return failure("Enter an archive note of 12–500 characters.");
  const auth = await owner();
  if (!auth) return failure("Only an owner or admin may resolve this exception.");
  const record = await target(auth, reviewId);
  if (!record || record.review.decision_status !== "retired" || record.relationship.is_active || !record.review.exception_record_id || !record.review.decision_evidence_ref)
    return failure("The relationship must be retired before its exception can be resolved.");
  const { data: exception } = await auth.supabase.from("unresolved_carrier_records")
    .select("id, status, record_type, record_id").eq("id", record.review.exception_record_id)
    .eq("organization_id", auth.orgId).maybeSingle();
  if (!exception || exception.record_type !== "factoring_relationship" || exception.record_id !== record.relationship.id || exception.status !== "unresolved")
    return failure("The open exception no longer matches this relationship. Refresh and inspect it.");
  const { data, error } = await auth.supabase.from("unresolved_carrier_records")
    .update({ status: "archived_legacy", resolved_by: auth.userId, resolved_at: new Date().toISOString(),
      resolution_note: `Retired test relationship review ${reviewId}; evidence ${record.review.decision_evidence_ref}: ${note.trim()}` })
    .eq("id", exception.id).eq("organization_id", auth.orgId).eq("record_type", "factoring_relationship")
    .eq("record_id", record.relationship.id).eq("status", "unresolved").select("id");
  if (error || data?.length !== 1) return failure("Resolution was not recorded. Refresh and inspect the exception.");
  revalidatePath(PATH);
  return { ok: true };
}
