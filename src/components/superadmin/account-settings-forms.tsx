"use client";

import { useActionState } from "react";
import { Loader2 } from "lucide-react";
import {
  updateAdminName,
  changeAdminEmail,
  changeAdminPassword,
  signOutOtherDevices,
  type SettingsState,
} from "@/app/(superadmin)/admin/settings/actions";

const initial: SettingsState = { ok: null, error: null };

const input =
  "h-9 w-full rounded-lg border border-slate-700 bg-slate-950/60 px-3 text-[13px] text-slate-100 placeholder:text-slate-600 outline-none focus-visible:border-blue-500 focus-visible:ring-2 focus-visible:ring-blue-500/20 disabled:opacity-60";
const label = "text-[12px] font-medium text-slate-300";
const card = "rounded-xl border border-slate-800 bg-slate-900/60 p-5";

function Result({ state }: { state: SettingsState }) {
  if (state.error) return <p role="alert" className="text-[12.5px] text-red-400">{state.error}</p>;
  if (state.ok) return <p role="status" className="text-[12.5px] text-emerald-400">{state.ok}</p>;
  return null;
}

function Submit({ pending, children }: { pending: boolean; children: React.ReactNode }) {
  return (
    <button type="submit" disabled={pending} className="inline-flex h-9 items-center gap-1.5 rounded-lg bg-blue-500 px-3.5 text-[12.5px] font-semibold text-white hover:bg-blue-400 disabled:opacity-60">
      {pending && <Loader2 className="size-3.5 animate-spin" />}
      {children}
    </button>
  );
}

export function NameForm({ fullName }: { fullName: string }) {
  const [state, action, pending] = useActionState(updateAdminName, initial);
  return (
    <form action={action} className={card}>
      <p className="text-sm font-semibold text-slate-100">Your name</p>
      <p className="mt-1 text-[12.5px] text-slate-500">Shown in the console header and on actions you take.</p>
      <div className="mt-4 space-y-1.5">
        <label htmlFor="full_name" className={label}>Full name</label>
        <input id="full_name" name="full_name" defaultValue={fullName} required maxLength={80} className={input} disabled={pending} />
      </div>
      <div className="mt-4 flex items-center gap-3">
        <Submit pending={pending}>Save name</Submit>
        <Result state={state} />
      </div>
    </form>
  );
}

export function EmailForm({ email, pendingEmail, hasPassword }: { email: string; pendingEmail: string | null; hasPassword: boolean }) {
  const [state, action, pending] = useActionState(changeAdminEmail, initial);
  return (
    <form action={action} className={card}>
      <p className="text-sm font-semibold text-slate-100">Sign-in email</p>
      <p className="mt-1 text-[12.5px] text-slate-500">
        Currently <span className="font-medium text-slate-300">{email}</span>. A confirmation link is emailed before the change takes effect.
      </p>
      {pendingEmail && (
        <p className="mt-3 rounded-lg border border-amber-500/25 bg-amber-500/10 px-3 py-2 text-[12px] text-amber-300">
          Waiting for you to confirm the change to <span className="font-medium">{pendingEmail}</span>. Check that inbox.
        </p>
      )}
      <div className="mt-4 grid gap-3 sm:grid-cols-2">
        <div className="space-y-1.5">
          <label htmlFor="email" className={label}>New email</label>
          <input id="email" name="email" type="email" autoComplete="email" required className={input} disabled={pending} />
        </div>
        {hasPassword && (
          <div className="space-y-1.5">
            <label htmlFor="email_current_password" className={label}>Current password</label>
            <input id="email_current_password" name="current_password" type="password" autoComplete="current-password" required className={input} disabled={pending} />
          </div>
        )}
      </div>
      <div className="mt-4 flex flex-wrap items-center gap-3">
        <Submit pending={pending}>Change email</Submit>
        <Result state={state} />
      </div>
    </form>
  );
}

export function PasswordForm({ hasPassword }: { hasPassword: boolean }) {
  const [state, action, pending] = useActionState(changeAdminPassword, initial);
  return (
    <form action={action} className={card}>
      <p className="text-sm font-semibold text-slate-100">{hasPassword ? "Password" : "Set a password"}</p>
      <p className="mt-1 text-[12.5px] text-slate-500">
        {hasPassword ? "At least 8 characters." : "You sign in with Google. Set a password to also sign in with your email."}
      </p>
      <div className="mt-4 grid gap-3 sm:grid-cols-3">
        {hasPassword && (
          <div className="space-y-1.5">
            <label htmlFor="current_password" className={label}>Current password</label>
            <input id="current_password" name="current_password" type="password" autoComplete="current-password" required className={input} disabled={pending} />
          </div>
        )}
        <div className="space-y-1.5">
          <label htmlFor="new_password" className={label}>New password</label>
          <input id="new_password" name="new_password" type="password" autoComplete="new-password" minLength={8} required className={input} disabled={pending} />
        </div>
        <div className="space-y-1.5">
          <label htmlFor="confirm_password" className={label}>Confirm new password</label>
          <input id="confirm_password" name="confirm_password" type="password" autoComplete="new-password" minLength={8} required className={input} disabled={pending} />
        </div>
      </div>
      <label className="mt-3 flex items-center gap-2 text-[12.5px] text-slate-400">
        <input type="checkbox" name="sign_out_others" defaultChecked className="size-4 rounded border-slate-600 bg-slate-900" />
        Sign out my other devices
      </label>
      <div className="mt-4 flex flex-wrap items-center gap-3">
        <Submit pending={pending}>{hasPassword ? "Change password" : "Set password"}</Submit>
        <Result state={state} />
      </div>
    </form>
  );
}

export function SessionsForm() {
  const [state, action, pending] = useActionState(signOutOtherDevices, initial);
  return (
    <form action={action} className={card}>
      <p className="text-sm font-semibold text-slate-100">Devices</p>
      <p className="mt-1 text-[12.5px] text-slate-500">Lost a laptop or signed in somewhere shared? Sign out everywhere except this device.</p>
      <div className="mt-4 flex flex-wrap items-center gap-3">
        <button type="submit" disabled={pending} className="inline-flex h-9 items-center gap-1.5 rounded-lg border border-slate-700 px-3.5 text-[12.5px] font-medium text-slate-200 hover:bg-slate-800 disabled:opacity-60">
          {pending && <Loader2 className="size-3.5 animate-spin" />}
          Sign out other devices
        </button>
        <Result state={state} />
      </div>
    </form>
  );
}
