import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { requireRole } from "@/lib/auth/require-role";
import { listSetupPackageCandidates } from "@/lib/carrier-setup-packages/candidates";
import { SetupPackageResourceNotFoundError } from "@/lib/carrier-setup-packages/errors";
import { PackageBuilder } from "./package-builder";

export default async function NewSetupPackagePage({ params }: { params: Promise<{ id: string }> }) {
  await requireRole(["owner", "admin", "dispatcher"]);
  const { id } = await params;
  const supabase = await createClient();
  let result;
  try {
    result = await Promise.all([
      supabase.from("carrier_onboarding_applications").select("id, status, legal_name, dba_name, mc_number, dot_number, converted_carrier_id").eq("id", id).maybeSingle(),
      supabase.from("brokers").select("id, company_name, contact_name, email").order("company_name"),
      listSetupPackageCandidates(id),
    ]);
  } catch (error) {
    if (error instanceof SetupPackageResourceNotFoundError) notFound();
    throw error;
  }
  const [{ data: application }, { data: brokers }, candidates] = result;
  if (!application) notFound();
  if (!["approved", "converted"].includes(application.status)) redirect(`/carriers/onboarding/${id}`);
  if (application.status === "converted") {
    const { data: convertedCarrier } = await supabase.from("carriers").select("is_active").eq("id", application.converted_carrier_id).maybeSingle();
    if (!convertedCarrier?.is_active) redirect(`/carriers/onboarding/${id}`);
  }
  return <PackageBuilder application={application} brokers={brokers ?? []} candidates={candidates} />;
}
