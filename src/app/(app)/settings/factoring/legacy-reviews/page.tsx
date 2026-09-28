import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { RetirementReviewClient } from "./retirement-review-client";

export default async function LegacyFactoringReviewsPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return <p>Sign in to review factoring relationships.</p>;
  const { data: profile } = await supabase.from("profiles")
    .select("role, organization_id").eq("id", user.id).maybeSingle();
  if (!profile || !["owner", "admin"].includes(profile.role))
    return <p>Only an owner or admin may review factoring relationship ownership.</p>;

  const { data: reviews, error } = await supabase.from("carrier_inference_review_0155")
    .select("id, relationship_id, prior_carrier_id, strict_status, evidence, decision_status, exception_record_id, updated_at, decision_evidence_ref")
    .eq("organization_id", profile.organization_id).eq("classification", "unsafe_assigned")
    .in("decision_status", ["pending", "retired"]).order("created_at").limit(100);
  if (error) return <p>The 0155 relationship review is unavailable. No change was made.</p>;
  const ids = (reviews ?? []).map((r) => r.relationship_id);
  const exceptionIds = (reviews ?? []).map((r) => r.exception_record_id).filter((id): id is string => Boolean(id));
  const [rels, exceptions] = await Promise.all([
    ids.length ? supabase.from("factoring_relationships")
      .select("id, relationship_name, carrier_id, is_active, is_default, updated_at")
      .eq("organization_id", profile.organization_id).in("id", ids) : Promise.resolve({ data: [] }),
    exceptionIds.length ? supabase.from("unresolved_carrier_records")
      .select("id, record_id, status").eq("organization_id", profile.organization_id).in("id", exceptionIds) : Promise.resolve({ data: [] }),
  ]);
  const relById = new Map((rels.data ?? []).map((r) => [r.id, r]));
  const excById = new Map((exceptions.data ?? []).map((e) => [e.id, e]));
  const rows = (reviews ?? []).map((r) => {
    const relationship = relById.get(r.relationship_id);
    const exception = r.exception_record_id ? excById.get(r.exception_record_id) : null;
    return {
      id: r.id, relationshipId: r.relationship_id,
      name: relationship?.relationship_name ?? "Relationship unavailable",
      carrierId: relationship?.carrier_id ?? null,
      isActive: relationship?.is_active ?? true,
      isDefault: relationship?.is_default ?? false,
      relationshipUpdatedAt: relationship?.updated_at ?? "",
      priorCarrierId: r.prior_carrier_id,
      reviewUpdatedAt: r.updated_at,
      decisionStatus: r.decision_status,
      strictStatus: r.strict_status,
      factoredInvoices: Number((r.evidence as { factored_invoices?: number } | null)?.factored_invoices ?? 0),
      unprovenInvoices: Number((r.evidence as { unproven_invoices?: number } | null)?.unproven_invoices ?? 0),
      exceptionStatus: exception?.record_id === r.relationship_id ? exception?.status ?? null : null,
      decisionEvidenceRef: r.decision_evidence_ref ?? null,
    };
  });
  return <div className="space-y-5 p-4">
    <Link className="text-sm underline" href="/settings/factoring">Back to factoring settings</Link>
    <h1 className="text-xl font-semibold">Historical relationship reviews</h1>
    <p className="text-sm text-muted-foreground">Owner/admin decisions are recorded. Retiring a relationship preserves historical invoices. A pending review or open exception keeps carrier-invoice factoring blocked.</p>
    <RetirementReviewClient rows={rows} />
  </div>;
}
