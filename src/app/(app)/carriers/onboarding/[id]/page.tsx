import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { getEffectiveOnboardingRequirements } from "@/lib/carrier-onboarding/requirements";
import { ApplicationDetail, type ApplicationDetailData } from "./application-detail";
import { getRequiredAgreementReadiness } from "@/lib/carrier-agreements/required-readiness";
import { W9_STAFF_SAFE_SELECT } from "@/lib/carrier-w9/types";

export default async function CarrierOnboardingApplicationPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const [{ data: roleData }, { data: application }] = await Promise.all([
    supabase.rpc("current_role"),
    supabase
      .from("carrier_onboarding_applications")
      .select(
        "id, organization_id, status, legal_name, dba_name, mc_number, dot_number, contact_name, phone, email, address_line1, address_line2, city, state, postal_code, country, ein_last4, factoring_company_name, has_factoring, proposed_dispatch_fee_percentage, proposed_payment_terms_days, equipment_data, application_notes, review_notes, created_at, submitted_at, reviewed_at, converted_at, converted_carrier_id, agreement_requirements_initialized_at"
      )
      .eq("id", id)
      .maybeSingle(),
  ]);
  if (!application) notFound();

  const role = (roleData as string | null) ?? "viewer";
  const canManage = ["owner", "admin", "dispatcher"].includes(role);
  const canConvert = role === "owner" || role === "admin";

  const [{ data: invitations }, { data: documents }, requirements, { data: signingRows }, { data: activity }, { data: publishedTemplates }, { data: packageRows }, requiredAgreementReadiness, { data: w9Row, error: w9Error }] = await Promise.all([
    supabase.from("carrier_onboarding_invitations").select("id, expires_at, created_at, first_viewed_at, last_viewed_at, revoked_at, submitted_at").eq("application_id", id).order("created_at", { ascending: false }),
    supabase.from("documents").select("id, document_type, file_name, file_path, is_verified, rejected_at, rejection_reason, created_at").eq("entity_type", "carrier_onboarding_application").eq("entity_id", id).order("created_at", { ascending: false }),
    getEffectiveOnboardingRequirements(supabase, application.organization_id),
    supabase.from("carrier_agreement_signings").select("id, status, agreement_template_id, signer_name, signer_title, signed_at, evidence_hash, assigned_at, generated_document_id, document_generation_status, document_generation_failure_reason").eq("application_id", id).order("assigned_at", { ascending: false }),
    supabase.from("activity_logs").select("id, action, created_at, changes, actor_id, profiles(full_name)").eq("entity_type", "carrier_onboarding_application").eq("entity_id", id).order("created_at", { ascending: false }),
    supabase.from("carrier_agreement_templates").select("id, template_key, name, version_number").eq("status", "published").order("name"),
    ["owner", "admin", "dispatcher", "accountant"].includes(role)
      ? supabase.from("carrier_setup_packages").select("id, version, status, prepared_for_name, recipient_name, document_count, generated_at, last_sent_at, generated_by").eq("onboarding_application_id", id).order("version", { ascending: false })
      : Promise.resolve({ data: [] as never[] }),
    getRequiredAgreementReadiness(supabase, id),
    // Phase 2N.2/2N.2A -- W-9 status for this application. 0099 is live.
    // Phase 2P.3A: carrier_w9s's authenticated SELECT grant deliberately
    // excludes tin_encrypted, so select("*") fails outright for every
    // authenticated caller (Postgres requires SELECT on every column of
    // the table for a bare "*") -- must use the exact safe column list.
    supabase.from("carrier_w9s").select(W9_STAFF_SAFE_SELECT).eq("onboarding_application_id", id).order("created_at", { ascending: false }).limit(1).maybeSingle(),
  ]);

  const generatedByIds = [...new Set((packageRows ?? []).map((p) => p.generated_by).filter((value): value is string => Boolean(value)))];
  const { data: generatorProfiles } = generatedByIds.length
    ? await supabase.from("profiles").select("id, full_name").in("id", generatedByIds)
    : { data: [] as { id: string; full_name: string }[] };
  const generatorById = new Map((generatorProfiles ?? []).map((profile) => [profile.id, profile]));

  // Phase 2L.4A -- there can legitimately be MORE THAN ONE active
  // (non-voided) signing on one application, one per distinct logical
  // agreement family (template_key) -- 0084's active-uniqueness guard
  // trigger guarantees at most one PER FAMILY, never that there's only
  // one overall. Every active signing is fetched and shown, never just
  // the first/most-recent one picked as if it were "the" signing.
  const activeSignings = signingRows ?? [];
  let signingDetails: ApplicationDetailData["signings"] = [];
  if (activeSignings.length > 0) {
    const templateIds = activeSignings.map((s) => s.agreement_template_id);
    const signingIds = activeSignings.map((s) => s.id);
    const [{ data: templates }, { data: clauseRows }, { data: initialRows }] = await Promise.all([
      supabase.from("carrier_agreement_templates").select("id, template_key, name, version_number, is_required_for_onboarding").in("id", templateIds),
      supabase.from("carrier_agreement_clauses").select("id, agreement_template_id, title, display_order, requires_initials").in("agreement_template_id", templateIds).order("display_order"),
      supabase.from("carrier_agreement_initials").select("signing_instance_id, clause_id, typed_initials").in("signing_instance_id", signingIds),
    ]);
    const templateById = new Map((templates ?? []).map((t) => [t.id, t]));

    signingDetails = activeSignings.map((signing) => {
      const template = templateById.get(signing.agreement_template_id);
      const clauses = (clauseRows ?? []).filter((c) => c.agreement_template_id === signing.agreement_template_id);
      return {
        id: signing.id,
        status: signing.status,
        templateKey: template?.template_key ?? "",
        templateName: template?.name ?? "Dispatch Agreement",
        templateVersion: template?.version_number ?? 1,
        isRequiredForOnboarding: template?.is_required_for_onboarding ?? false,
        signerName: signing.signer_name,
        signerTitle: signing.signer_title,
        signedAt: signing.signed_at,
        evidenceHash: signing.evidence_hash,
        generatedDocumentId: signing.generated_document_id,
        documentGenerationStatus: signing.document_generation_status ?? "pending",
        documentGenerationFailureReason: signing.document_generation_failure_reason,
        clauses: clauses.map((c) => ({
          id: c.id,
          title: c.title,
          requiresInitials: c.requires_initials,
          typedInitials: (initialRows ?? []).find((i) => i.signing_instance_id === signing.id && i.clause_id === c.id)?.typed_initials ?? null,
        })),
      };
    });
  }

  const documentsByType = new Map((documents ?? []).map((d) => [d.document_type, d]));
  const checklist = requirements.map((req) => {
    const doc = documentsByType.get(req.documentType);
    return {
      ...req,
      documentId: doc?.id ?? null,
      fileName: doc?.file_name ?? null,
      storagePath: doc?.file_path ?? null,
      isVerified: doc?.is_verified ?? false,
      rejectedAt: doc?.rejected_at ?? null,
      rejectionReason: doc?.rejection_reason ?? null,
    };
  });

  const data: ApplicationDetailData = {
    id: application.id,
    status: application.status,
    legalName: application.legal_name,
    dbaName: application.dba_name,
    mcNumber: application.mc_number,
    dotNumber: application.dot_number,
    contactName: application.contact_name,
    phone: application.phone,
    email: application.email,
    addressLine1: application.address_line1,
    addressLine2: application.address_line2,
    city: application.city,
    state: application.state,
    postalCode: application.postal_code,
    country: application.country,
    einLast4: application.ein_last4,
    factoringCompanyName: application.factoring_company_name,
    hasFactoring: application.has_factoring,
    proposedDispatchFeePercentage: application.proposed_dispatch_fee_percentage != null ? Number(application.proposed_dispatch_fee_percentage) : null,
    proposedPaymentTermsDays: application.proposed_payment_terms_days,
    equipmentData: (application.equipment_data as Record<string, unknown> | null) ?? null,
    reviewNotes: application.review_notes,
    createdAt: application.created_at,
    submittedAt: application.submitted_at,
    reviewedAt: application.reviewed_at,
    convertedAt: application.converted_at,
    convertedCarrierId: application.converted_carrier_id,
    requiredAgreementReadiness,
    invitations: (invitations ?? []).map((i) => ({
      id: i.id,
      expiresAt: i.expires_at,
      createdAt: i.created_at,
      firstViewedAt: i.first_viewed_at,
      lastViewedAt: i.last_viewed_at,
      revokedAt: i.revoked_at,
      submittedAt: i.submitted_at,
    })),
    checklist,
    signings: signingDetails,
    activity: (activity ?? []).map((a) => ({
      id: a.id,
      action: a.action,
      createdAt: a.created_at,
      actorName: (a.profiles as unknown as { full_name: string } | null)?.full_name ?? null,
      changes: a.changes as Record<string, unknown> | null,
    })),
    publishedTemplates: publishedTemplates ?? [],
    setupPackages: (packageRows ?? []).map((pkg) => ({ ...pkg, generated_by_profile: pkg.generated_by ? generatorById.get(pkg.generated_by) ?? null : null })),
    w9: (w9Row as ApplicationDetailData["w9"]) ?? null,
    w9LoadError: w9Error?.message ?? null,
    organizationId: application.organization_id,
  };

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs
        tabs={[
          { label: "Carrier Onboarding", href: "/carriers/onboarding" },
          { label: application.legal_name ?? "Application", href: `/carriers/onboarding/${id}` },
        ]}
      />
      <ApplicationDetail data={data} canManage={canManage} canConvert={canConvert} canViewPackages={["owner", "admin", "dispatcher", "accountant"].includes(role)} role={role} />
    </div>
  );
}
