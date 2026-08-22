import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { TemplateEditor } from "./template-editor";

export default async function CarrierAgreementTemplateDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const [{ data: roleData }, { data: template }] = await Promise.all([
    supabase.rpc("current_role"),
    supabase
      .from("carrier_agreement_templates")
      .select("id, template_key, version_number, name, description, status, is_required_for_onboarding, requires_signer_title, published_at")
      .eq("id", id)
      .maybeSingle(),
  ]);
  if (!template) notFound();

  const { data: clauses } = await supabase
    .from("carrier_agreement_clauses")
    .select("id, clause_key, title, body, display_order, requires_initials")
    .eq("agreement_template_id", id)
    .order("display_order");

  const canManage = roleData === "owner" || roleData === "admin";

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs
        tabs={[
          { label: "Carrier Onboarding", href: "/carriers/onboarding" },
          { label: "Agreement Templates", href: "/carriers/onboarding/templates" },
          { label: `${template.name} (v${template.version_number})`, href: `/carriers/onboarding/templates/${id}` },
        ]}
      />
      <TemplateEditor template={template} initialClauses={clauses ?? []} canManage={canManage} />
    </div>
  );
}
