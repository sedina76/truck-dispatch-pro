import { notFound } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { CompanyProfileForm } from "@/components/superadmin/company-profile-form";
import { ArrowLeft, Building2 } from "lucide-react";

// Dedicated Edit Company page (as opposed to the in-tab "Company Profile"
// editor on the detail page) -- reuses the exact same CompanyProfileForm
// and updateCompanyProfile server action, just in redirect-on-save mode.
// The (superadmin) layout already re-verifies is_platform_admin() before
// this page renders at all; updateCompanyProfile() re-verifies it again
// itself when the form actually submits.
export default async function EditCompanyPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: org } = await supabase
    .from("organizations")
    .select("id, name, slug, dba_name, business_phone, business_email, website, address_line1, city, state, postal_code, country, timezone")
    .eq("id", id)
    .single();

  if (!org) notFound();

  return (
    <div className="max-w-2xl space-y-5">
      <div>
        <Link href={`/admin/companies/${id}`} className="flex items-center gap-1.5 text-[12.5px] font-medium text-slate-400 hover:text-slate-200">
          <ArrowLeft className="size-3.5" /> Back to {org.name}
        </Link>
        <div className="mt-3 flex items-center gap-2.5">
          <div className="flex size-9 items-center justify-center rounded-lg bg-blue-500/10 text-blue-400">
            <Building2 className="size-4.5" />
          </div>
          <div>
            <h1 className="text-lg font-semibold text-slate-50">Edit Company</h1>
            <p className="text-[12.5px] text-slate-500">{org.name}</p>
          </div>
        </div>
      </div>

      <CompanyProfileForm org={org} redirectTo={`/admin/companies/${id}`} />
    </div>
  );
}
