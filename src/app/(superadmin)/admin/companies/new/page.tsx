import Link from "next/link";
import { ArrowLeft } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { AddCompanyForm } from "@/components/superadmin/add-company-form";

// Real tenant onboarding workflow (spec sections 10-12), not a
// placeholder -- see createCompany in platform-actions.ts for the full
// create-auth-user -> create-org-with-owner -> rollback-on-failure sequence.
export default async function AddCompanyPage() {
  const supabase = await createClient();
  const { data: plans } = await supabase
    .from("subscription_plans")
    .select("id, name, monthly_price_cents")
    .eq("is_active", true)
    .order("monthly_price_cents");

  return (
    <div className="max-w-2xl space-y-6">
      <div className="flex items-center gap-2">
        <Link href="/admin/companies" className="text-slate-500 hover:text-slate-300">
          <ArrowLeft className="size-4" />
        </Link>
        <PageHeader title="Add Company" description="Provision a new tenant and its primary admin account." />
      </div>
      <AddCompanyForm plans={plans ?? []} />
    </div>
  );
}
