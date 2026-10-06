import Link from "next/link";
import { CheckCircle2, AlertTriangle, XCircle } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { getPlatformConfigChecks, type ConfigCheck } from "@/lib/superadmin/platform-config";
import { getPlatformOverview } from "@/lib/superadmin/platform-metrics";
import { NameForm, EmailForm, PasswordForm, SessionsForm } from "@/components/superadmin/account-settings-forms";

export const metadata = { title: "Settings · Platform Console" };

const STATE_ICON: Record<ConfigCheck["state"], React.ReactNode> = {
  ok: <CheckCircle2 className="size-4 text-emerald-400" />,
  warn: <AlertTriangle className="size-4 text-amber-400" />,
  missing: <XCircle className="size-4 text-red-400" />,
};

export default async function PlatformSettingsPage() {
  const supabase = await createClient();
  const [{ data: { user } }, overview] = await Promise.all([supabase.auth.getUser(), getPlatformOverview()]);
  const { data: admin } = user ? await supabase.from("platform_admins").select("full_name").eq("id", user.id).maybeSingle() : { data: null };

  const hasPassword = (user?.identities ?? []).some((i) => i.provider === "email");
  const checks = getPlatformConfigChecks();
  const { totals } = overview;

  return (
    <div className="max-w-4xl space-y-6">
      <div>
        <h1 className="text-xl font-semibold tracking-tight text-slate-50">Settings</h1>
        <p className="mt-1 text-sm text-slate-400">Your Platform Console sign-in, and whether the platform is fully set up.</p>
      </div>

      <section className="space-y-3" aria-labelledby="account-title">
        <h2 id="account-title" className="text-sm font-semibold text-slate-100">Your account</h2>
        <NameForm fullName={admin?.full_name ?? ""} />
        <EmailForm email={user?.email ?? ""} pendingEmail={user?.new_email ?? null} hasPassword={hasPassword} />
        <PasswordForm hasPassword={hasPassword} />
        <SessionsForm />
      </section>

      <section className="space-y-3" aria-labelledby="setup-title">
        <h2 id="setup-title" className="text-sm font-semibold text-slate-100">Platform setup</h2>
        <div className="divide-y divide-slate-800 rounded-xl border border-slate-800 bg-slate-900/60">
          {checks.map((c) => (
            <div key={c.label} className="flex items-start gap-3 px-5 py-3.5">
              <span className="mt-0.5">{STATE_ICON[c.state]}</span>
              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <p className="text-[13px] font-medium text-slate-200">{c.label}</p>
                  <p className="text-[12.5px] text-slate-400">{c.value}</p>
                </div>
                <p className="mt-0.5 text-[12px] text-slate-500">{c.help}</p>
              </div>
            </div>
          ))}
          <div className="flex items-start gap-3 px-5 py-3.5">
            <span className="mt-0.5">{totals.lockedCount > 0 ? STATE_ICON.missing : STATE_ICON.ok}</span>
            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap items-baseline justify-between gap-2">
                <p className="text-[13px] font-medium text-slate-200">Company access</p>
                <p className="text-[12.5px] text-slate-400">
                  {totals.lockedCount} locked out · {totals.freeCount} free access · {totals.suspendedCount} suspended
                </p>
              </div>
              <p className="mt-0.5 text-[12px] text-slate-500">
                {totals.lockedCount > 0 ? "Some companies can't use the app. " : ""}
                See who has access, and why, in <Link href="/admin/reports" className="text-blue-400 hover:text-blue-300">Reports</Link>.
              </p>
            </div>
          </div>
        </div>
        <p className="text-[12px] text-slate-500">
          Other people with console access are managed under <Link href="/admin/admins" className="text-blue-400 hover:text-blue-300">Platform Admins</Link>.
        </p>
      </section>
    </div>
  );
}
