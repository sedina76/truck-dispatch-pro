import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { SuperAdminSidebar } from "@/components/superadmin/superadmin-sidebar";
import { TooltipProvider } from "@/components/ui/tooltip";

export default async function SuperAdminLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: isPlatformAdmin } = await supabase.rpc("is_platform_admin");
  if (!isPlatformAdmin) redirect("/dashboard");

  return (
    <TooltipProvider delayDuration={200}>
      {/* Platform Console always renders in its own dark navy premium
          treatment, independent of the tenant app's light/dark toggle --
          same "consistent own look regardless of theme" convention the
          Driver Portal and desktop ERP shell already use. The `dark`
          class forces every shared component still used by the
          untouched Companies/Company Detail/Platform Admins pages
          (PageHeader, DataTable, StatusBadge, Button, ...) to resolve
          their CSS-variable-driven colors to the app's existing dark
          palette too, so the whole console reads as one consistent
          surface instead of light-themed cards on a dark shell. */}
      <div className="dark flex h-screen bg-slate-950">
        <SuperAdminSidebar />
        <main className="flex-1 overflow-y-auto overflow-x-hidden px-6 py-6 md:px-8 md:py-7">{children}</main>
      </div>
    </TooltipProvider>
  );
}
