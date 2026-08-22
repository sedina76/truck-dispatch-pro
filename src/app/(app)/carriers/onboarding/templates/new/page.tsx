import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormTextarea } from "@/components/ui/form-field";
import { createNewTemplate } from "../actions";

export default async function NewCarrierAgreementTemplatePage() {
  const supabase = await createClient();
  const { data: roleData } = await supabase.rpc("current_role");
  if (roleData !== "owner" && roleData !== "admin") redirect("/carriers/onboarding/templates");

  return (
    <FormCard
      title="New Agreement Template"
      description="Starts as a draft -- freely editable until you publish it."
      action={createNewTemplate}
      cancelHref="/carriers/onboarding/templates"
      submitLabel="Create Draft"
    >
      <FormGrid>
        <FormField label="Name" name="name" required placeholder="Standard Dispatch Agreement" />
        <FormField label="Key (optional -- auto-generated from name)" name="template_key" placeholder="standard_dispatch_agreement" />
      </FormGrid>
      <FormTextarea label="Description (optional)" name="description" rows={2} />
    </FormCard>
  );
}
