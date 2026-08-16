import { notFound } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { AddAdminPageForm } from "@/components/superadmin/add-admin-page-form";
import { ArrowLeft, UserPlus } from "lucide-react";

export default async function AddCompanyAdminPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: org } = await supabase.from("organizations").select("id, name").eq("id", id).single();
  if (!org) notFound();

  const backHref = `/admin/companies/${id}?tab=admins`;

  return (
    <div className="max-w-lg space-y-5">
      <div>
        <Link href={backHref} className="flex items-center gap-1.5 text-[12.5px] font-medium text-slate-400 hover:text-slate-200">
          <ArrowLeft className="size-3.5" /> Back to {org.name}
        </Link>
        <div className="mt-3 flex items-center gap-2.5">
          <div className="flex size-9 items-center justify-center rounded-lg bg-blue-500/10 text-blue-400">
            <UserPlus className="size-4.5" />
          </div>
          <div>
            <h1 className="text-lg font-semibold text-slate-50">Add Admin</h1>
            <p className="text-[12.5px] text-slate-500">{org.name}</p>
          </div>
        </div>
      </div>

      <AddAdminPageForm orgId={id} backHref={backHref} />
    </div>
  );
}
