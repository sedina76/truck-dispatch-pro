import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

export type RequiredAgreementReadiness = {
  initializedAt: string | null;
  initialized: boolean;
  ready: boolean;
  completedCount: number;
  requirements: Array<{
    templateKey: string;
    initialTemplateId: string;
    initialTemplateName: string;
    initialTemplateVersion: number;
    signingId: string | null;
    signingStatus: string | null;
    signingTemplateName: string | null;
    signingTemplateVersion: number | null;
  }>;
};

export async function getRequiredAgreementReadiness(
  supabase: SupabaseClient,
  applicationId: string,
): Promise<RequiredAgreementReadiness> {
  const { data: application } = await supabase
    .from("carrier_onboarding_applications")
    .select("agreement_requirements_initialized_at")
    .eq("id", applicationId)
    .maybeSingle();

  const initializedAt = application?.agreement_requirements_initialized_at ?? null;
  if (!initializedAt) {
    return { initializedAt: null, initialized: false, ready: false, completedCount: 0, requirements: [] };
  }

  const [{ data: requirementRows }, { data: signingRows }] = await Promise.all([
    supabase
      .from("carrier_onboarding_agreement_requirements")
      .select("template_key, initial_template_id")
      .eq("onboarding_application_id", applicationId)
      .order("template_key"),
    supabase
      .from("carrier_agreement_signings")
      .select("id, status, agreement_template_id")
      .eq("application_id", applicationId)
      .neq("status", "voided"),
  ]);

  const templateIds = [...new Set([
    ...(requirementRows ?? []).map((row) => row.initial_template_id),
    ...(signingRows ?? []).map((row) => row.agreement_template_id),
  ])];
  const { data: templateRows } = templateIds.length
    ? await supabase
        .from("carrier_agreement_templates")
        .select("id, template_key, name, version_number")
        .in("id", templateIds)
    : { data: [] };
  const templatesById = new Map((templateRows ?? []).map((row) => [row.id, row]));
  const activeSigningByKey = new Map<string, NonNullable<typeof signingRows>[number]>();
  for (const signing of signingRows ?? []) {
    const key = templatesById.get(signing.agreement_template_id)?.template_key;
    if (key) activeSigningByKey.set(key, signing);
  }

  const requirements = (requirementRows ?? []).map((row) => {
    const initialTemplate = templatesById.get(row.initial_template_id);
    const signing = activeSigningByKey.get(row.template_key) ?? null;
    const signingTemplate = signing ? templatesById.get(signing.agreement_template_id) : null;
    return {
      templateKey: row.template_key,
      initialTemplateId: row.initial_template_id,
      initialTemplateName: initialTemplate?.name ?? row.template_key,
      initialTemplateVersion: initialTemplate?.version_number ?? 1,
      signingId: signing?.id ?? null,
      signingStatus: signing?.status ?? null,
      signingTemplateName: signingTemplate?.name ?? null,
      signingTemplateVersion: signingTemplate?.version_number ?? null,
    };
  });
  const completedCount = requirements.filter((row) => row.signingStatus === "completed").length;
  return {
    initializedAt,
    initialized: true,
    ready: completedCount === requirements.length,
    completedCount,
    requirements,
  };
}
