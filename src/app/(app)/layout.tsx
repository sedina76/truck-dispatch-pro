import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { Sidebar } from "@/components/nav/sidebar";
import { CommandPalette } from "@/components/nav/command-palette";
import { TooltipProvider } from "@/components/ui/tooltip";
import { DesktopTitleBar } from "@/components/desktop/title-bar";
import { DesktopMenuBar } from "@/components/desktop/menu-bar";
import { DesktopToolbar } from "@/components/desktop/toolbar";
import { DesktopStatusBar } from "@/components/desktop/status-bar";
import { DesktopActionsProvider } from "@/components/desktop/actions-context";
import { ToastProvider } from "@/components/ui/toast";

// The subscription-status access gate itself lives in middleware.ts, which
// has direct access to the request path -- no fragile cross-request header
// forwarding needed to avoid redirect-looping on /settings/subscription.
export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data } = await supabase
    .from("profiles")
    .select("full_name, role, organization_id, organizations(name)")
    .eq("id", user.id)
    .single();

  // TODO: drop this cast once src/types/supabase.ts holds real generated
  // types (see that file's header) -- the placeholder Database type can't
  // express this shape, so Supabase's query builder falls back to `Json`.
  const profile = data as unknown as {
    full_name: string;
    role: string;
    organization_id: string | null;
    organizations: { name: string } | null;
  } | null;

  if (!profile?.organization_id) {
    const { data: isPlatformAdmin } = await supabase.rpc("is_platform_admin");
    redirect(isPlatformAdmin ? "/admin/dashboard" : "/onboarding");
  }

  const organizationName = profile.organizations?.name ?? "Your organization";

  const { data: notifications } = await supabase
    .from("notifications")
    .select("id, title, body, type, read_at, created_at")
    .eq("profile_id", user.id)
    .order("created_at", { ascending: false })
    .limit(20);

  return (
    <TooltipProvider delayDuration={200}>
      <ToastProvider>
      <DesktopActionsProvider>
        <div className="flex h-screen flex-col bg-desktop-bg">
          {/* Every shell chrome element below is `no-print` -- printing
              any page inside (app) (via the toolbar's Print button or a
              plain Ctrl/Cmd+P) never includes the title bar, menu bar,
              toolbar, sidebar, or status bar, only `main`'s own content.
              This is what makes window.print() usable directly from
              in-shell pages (Driver Profile, Profitability Report, etc.)
              without a dedicated print route, and also fixes the same gap
              for the carrier/driver-settlement PDF routes, which live
              inside (app) unlike invoices/payments. */}
          <div className="no-print"><DesktopTitleBar organizationName={organizationName} /></div>
          <div className="no-print"><DesktopMenuBar /></div>
          <div className="no-print"><DesktopToolbar notifications={notifications ?? []} /></div>
          <div className="flex flex-1 overflow-hidden">
            <div className="no-print"><Sidebar organizationName={organizationName} fullName={profile.full_name} role={profile.role} /></div>
            <main className="flex-1 overflow-y-auto px-4 py-3 print:overflow-visible print:p-0">{children}</main>
          </div>
          <div className="no-print"><DesktopStatusBar fullName={profile.full_name} role={profile.role} organizationName={organizationName} /></div>
        </div>
        <CommandPalette />
      </DesktopActionsProvider>
      </ToastProvider>
    </TooltipProvider>
  );
}
