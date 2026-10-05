"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { STARTER_TEMPLATES, renderStarter, unfilledBlanks, clauseKey } from "@/lib/carrier-onboarding/starter-templates";

// Phase 2L.4 -- template/clause management. Every write here is a plain
// RLS-scoped client update -- carrier_agreement_templates_insert/_update
// (0082) already restrict these to owner/admin, and the immutability
// trigger already blocks any mutation once a template leaves draft. This
// file adds NOTHING to that boundary; it only calls it. No service-role
// client anywhere in this file.

function str(formData: FormData, key: string): string | null {
  const v = formData.get(key);
  if (typeof v !== "string") return null;
  const trimmed = v.trim();
  return trimmed === "" ? null : trimmed;
}

export async function createNewTemplate(formData: FormData) {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const name = str(formData, "name");
  if (!name) throw new Error("Name is required.");
  const templateKey = str(formData, "template_key") ?? name.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");

  const { data, error } = await supabase
    .from("carrier_agreement_templates")
    .insert({
      organization_id: organizationId,
      template_key: templateKey,
      version_number: 1,
      name,
      description: str(formData, "description"),
      created_by: user?.id ?? null,
    })
    .select("id")
    .single();
  if (error) throw new Error(error.message);

  revalidatePath("/carriers/onboarding/templates");
  redirect(`/carriers/onboarding/templates/${data.id}`);
}

// Clones an existing template's own name/description/flags + every
// clause into a brand-new draft row with the SAME template_key and
// version_number + 1 -- never edits the source row (0082's own
// immutability guarantee), matching this schema's row-per-version design
// exactly.
export async function createNewVersion(sourceTemplateId: string) {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: source, error: sourceError } = await supabase
    .from("carrier_agreement_templates")
    .select("template_key, version_number, name, description, is_required_for_onboarding, requires_signer_title")
    .eq("id", sourceTemplateId)
    .single();
  if (sourceError || !source) throw new Error("Source template not found.");

  const { data: latest } = await supabase
    .from("carrier_agreement_templates")
    .select("version_number")
    .eq("organization_id", organizationId)
    .eq("template_key", source.template_key)
    .order("version_number", { ascending: false })
    .limit(1)
    .single();

  const { data: created, error: createError } = await supabase
    .from("carrier_agreement_templates")
    .insert({
      organization_id: organizationId,
      template_key: source.template_key,
      version_number: (latest?.version_number ?? source.version_number) + 1,
      name: source.name,
      description: source.description,
      is_required_for_onboarding: source.is_required_for_onboarding,
      requires_signer_title: source.requires_signer_title,
      created_by: user?.id ?? null,
    })
    .select("id")
    .single();
  if (createError) throw new Error(createError.message);

  const { data: clauses } = await supabase
    .from("carrier_agreement_clauses")
    .select("clause_key, title, body, display_order, requires_initials")
    .eq("agreement_template_id", sourceTemplateId)
    .order("display_order");

  if (clauses && clauses.length > 0) {
    const { error: clauseError } = await supabase.from("carrier_agreement_clauses").insert(
      clauses.map((c) => ({
        organization_id: organizationId,
        agreement_template_id: created.id,
        clause_key: c.clause_key,
        title: c.title,
        body: c.body,
        display_order: c.display_order,
        requires_initials: c.requires_initials,
      }))
    );
    if (clauseError) throw new Error(clauseError.message);
  }

  revalidatePath("/carriers/onboarding/templates");
  redirect(`/carriers/onboarding/templates/${created.id}`);
}

export async function updateTemplateMeta(templateId: string, formData: FormData): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();
  const name = str(formData, "name");
  if (!name) return { ok: false, error: "Name is required." };

  const { error } = await supabase
    .from("carrier_agreement_templates")
    .update({
      name,
      description: str(formData, "description"),
      requires_signer_title: formData.get("requires_signer_title") === "on",
      is_required_for_onboarding: formData.get("is_required_for_onboarding") === "on",
    })
    .eq("id", templateId);
  if (error) return { ok: false, error: error.message };

  revalidatePath(`/carriers/onboarding/templates/${templateId}`);
  return { ok: true };
}

export async function addClause(templateId: string, formData: FormData): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  const title = str(formData, "title");
  const body = str(formData, "body");
  if (!title || !body) return { ok: false, error: "Title and body are required." };

  const { count } = await supabase.from("carrier_agreement_clauses").select("id", { count: "exact", head: true }).eq("agreement_template_id", templateId);
  const clauseKey = str(formData, "clause_key") ?? title.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");

  const { error } = await supabase.from("carrier_agreement_clauses").insert({
    organization_id: organizationId,
    agreement_template_id: templateId,
    clause_key: clauseKey,
    title,
    body,
    display_order: count ?? 0,
    requires_initials: formData.get("requires_initials") === "on",
  });
  if (error) return { ok: false, error: error.message };

  revalidatePath(`/carriers/onboarding/templates/${templateId}`);
  return { ok: true };
}

export async function updateClause(clauseId: string, templateId: string, formData: FormData): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();
  const title = str(formData, "title");
  const body = str(formData, "body");
  if (!title || !body) return { ok: false, error: "Title and body are required." };

  const { error } = await supabase
    .from("carrier_agreement_clauses")
    .update({ title, body, requires_initials: formData.get("requires_initials") === "on" })
    .eq("id", clauseId);
  if (error) return { ok: false, error: error.message };

  revalidatePath(`/carriers/onboarding/templates/${templateId}`);
  return { ok: true };
}

export async function deleteClause(clauseId: string, templateId: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();
  const { error } = await supabase.from("carrier_agreement_clauses").delete().eq("id", clauseId);
  if (error) return { ok: false, error: error.message };
  revalidatePath(`/carriers/onboarding/templates/${templateId}`);
  return { ok: true };
}

export async function reorderClauses(templateId: string, orderedClauseIds: string[]): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();
  for (let i = 0; i < orderedClauseIds.length; i++) {
    const { error } = await supabase.from("carrier_agreement_clauses").update({ display_order: i }).eq("id", orderedClauseIds[i]);
    if (error) return { ok: false, error: error.message };
  }
  revalidatePath(`/carriers/onboarding/templates/${templateId}`);
  return { ok: true };
}

export async function publishTemplate(templateId: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: template, error: templateError } = await supabase
    .from("carrier_agreement_templates")
    .select("organization_id, template_key, status")
    .eq("id", templateId)
    .maybeSingle();
  if (templateError || !template) return { ok: false, error: "Template not found." };
  if (template.status !== "draft") return { ok: false, error: "Only a draft template can be published." };

  const { data: publishedVersion } = await supabase
    .from("carrier_agreement_templates")
    .select("id")
    .eq("organization_id", template.organization_id)
    .eq("template_key", template.template_key)
    .eq("status", "published")
    .neq("id", templateId)
    .limit(1)
    .maybeSingle();
  if (publishedVersion) {
    return { ok: false, error: "Another version of this agreement is currently published. Retire it before publishing this version." };
  }

  const { data: clauses } = await supabase.from("carrier_agreement_clauses").select("id, title, body").eq("agreement_template_id", templateId);
  if (!clauses || clauses.length === 0) return { ok: false, error: "Add at least one clause before publishing." };
  // A blank like [STATE] left in the text would be locked in for good.
  const blanks = unfilledBlanks(clauses.flatMap((c) => [c.title as string, c.body as string]));
  if (blanks.length > 0) return { ok: false, error: `Fill in ${blanks.join(", ")} in the clause text before publishing.` };

  const { data: hash, error: hashError } = await supabase.rpc("compute_carrier_agreement_content_hash", { p_template_id: templateId });
  if (hashError) return { ok: false, error: hashError.message };

  const { error } = await supabase
    .from("carrier_agreement_templates")
    .update({ status: "published", content_hash: hash, published_at: new Date().toISOString(), published_by: user?.id ?? null })
    .eq("id", templateId);
  if (error) {
    if (error.code === "23505" || error.message.includes("carrier_agreement_templates_one_published_per_key_idx")) {
      return { ok: false, error: "Another version of this agreement is currently published. Retire it before publishing this version." };
    }
    return { ok: false, error: error.message };
  }

  revalidatePath(`/carriers/onboarding/templates/${templateId}`);
  revalidatePath("/carriers/onboarding/templates");
  return { ok: true };
}

export async function retireTemplate(templateId: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();
  const { error } = await supabase.from("carrier_agreement_templates").update({ status: "retired" }).eq("id", templateId);
  if (error) return { ok: false, error: error.message };
  revalidatePath(`/carriers/onboarding/templates/${templateId}`);
  revalidatePath("/carriers/onboarding/templates");
  return { ok: true };
}

/**
 * Adds the standard agreements (Dispatch Service Agreement, Limited
 * Authorization, Tracking & Communications Consent) as DRAFTS with this
 * company's name and state filled in. Skips any the company already has
 * (same key, any version). Owner/admin only (RLS on the template tables).
 */
export async function addStarterTemplates(): Promise<{ ok: true; added: string[] } | { ok: false; error: string }> {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const [{ data: org }, { data: existing }] = await Promise.all([
    supabase.from("organizations").select("name, state").eq("id", organizationId).maybeSingle(),
    supabase.from("carrier_agreement_templates").select("template_key").eq("organization_id", organizationId),
  ]);
  const have = new Set(((existing ?? []) as { template_key: string }[]).map((t) => t.template_key));
  const added: string[] = [];

  for (const starter of STARTER_TEMPLATES) {
    if (have.has(starter.key)) continue;
    const t = renderStarter(starter, { name: (org?.name as string | undefined) ?? "", state: (org?.state as string | null | undefined) ?? null });
    const { data: created, error } = await supabase
      .from("carrier_agreement_templates")
      .insert({
        organization_id: organizationId,
        template_key: t.key,
        version_number: 1,
        name: t.name,
        description: t.description,
        is_required_for_onboarding: t.requiredForOnboarding,
        requires_signer_title: t.requiresSignerTitle,
        created_by: user?.id ?? null,
      })
      .select("id")
      .single();
    if (error || !created) {
      return { ok: false, error: /row-level security|permission/i.test(error?.message ?? "") ? "Only an owner or admin can add agreement templates." : "Could not add the standard agreements. Please try again." };
    }
    const { error: clauseError } = await supabase.from("carrier_agreement_clauses").insert(
      t.clauses.map((c, i) => ({
        organization_id: organizationId,
        agreement_template_id: created.id,
        clause_key: clauseKey(c.title),
        title: c.title,
        body: c.body,
        display_order: i,
        requires_initials: c.requiresInitials,
      }))
    );
    if (clauseError) {
      await supabase.from("carrier_agreement_templates").delete().eq("id", created.id);
      return { ok: false, error: "Could not add the standard agreements. Please try again." };
    }
    added.push(t.name);
  }

  revalidatePath("/carriers/onboarding/templates");
  return { ok: true, added };
}
