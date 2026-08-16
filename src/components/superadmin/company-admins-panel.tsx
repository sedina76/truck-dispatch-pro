"use client";

import { useState } from "react";
import { Loader2, UserPlus, Pencil, KeyRound, UserX, UserCheck } from "lucide-react";
import {
  addCompanyAdmin,
  updateAdminProfile,
  changeAdminRole,
  setAdminActive,
  setTemporaryPassword,
  sendPasswordResetEmail,
} from "@/app/(superadmin)/admin/companies/platform-actions";
import { TempPasswordReveal } from "./temp-password-reveal";

export type AdminRow = {
  id: string;
  fullName: string;
  email: string;
  phone: string | null;
  role: string;
  isActive: boolean;
  createdAt: string;
  lastSignInAt: string | null;
  isLastOwner: boolean;
};

const VALID_ROLES = ["owner", "admin", "dispatcher", "accountant", "driver", "viewer"];
const inputClass = "h-9 w-full rounded-lg border border-slate-700 bg-slate-950 px-2.5 text-[12.5px] text-slate-100 outline-none focus-visible:border-blue-500";

export function CompanyAdminsPanel({ orgId, admins }: { orgId: string; admins: AdminRow[] }) {
  const [showAdd, setShowAdd] = useState(false);
  const [editing, setEditing] = useState<AdminRow | null>(null);
  const [reveal, setReveal] = useState<{ email: string; password: string } | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function handleReset(admin: AdminRow) {
    setBusyId(admin.id);
    setError(null);
    try {
      const { tempPassword } = await setTemporaryPassword(admin.id, orgId);
      setReveal({ email: admin.email, password: tempPassword });
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not reset password.");
    } finally {
      setBusyId(null);
    }
  }

  async function handleToggleActive(admin: AdminRow) {
    setBusyId(admin.id);
    setError(null);
    try {
      await setAdminActive(admin.id, orgId, !admin.isActive);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not update access.");
    } finally {
      setBusyId(null);
    }
  }

  async function handleRoleChange(admin: AdminRow, role: string) {
    if (role === admin.role) return;
    setBusyId(admin.id);
    setError(null);
    try {
      const fd = new FormData();
      fd.set("role", role);
      await changeAdminRole(admin.id, orgId, fd);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not change role.");
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="space-y-4">
      {error && <p className="rounded-lg border border-red-500/20 bg-red-500/5 px-3 py-2 text-[12.5px] text-red-400">{error}</p>}

      <div className="flex justify-end">
        <button
          type="button"
          onClick={() => setShowAdd(true)}
          className="flex h-9 items-center gap-1.5 rounded-lg bg-blue-500 px-3 text-[12.5px] font-semibold text-white hover:bg-blue-600"
        >
          <UserPlus className="size-3.5" /> Add Admin
        </button>
      </div>

      <div className="overflow-x-auto rounded-xl border border-slate-800 bg-slate-900/60">
        <table className="w-full text-[13px]">
          <thead>
            <tr className="border-b border-slate-800 text-left text-[10.5px] font-semibold uppercase tracking-wide text-slate-500">
              <th className="px-4 py-2.5">Name</th>
              <th className="px-3 py-2.5">Email</th>
              <th className="px-3 py-2.5">Role</th>
              <th className="px-3 py-2.5">Status</th>
              <th className="px-3 py-2.5">Last Sign-In</th>
              <th className="px-3 py-2.5">Created</th>
              <th className="px-4 py-2.5 text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            {admins.map((a) => (
              <tr key={a.id} className="border-b border-slate-800/70 last:border-0">
                <td className="px-4 py-2.5 font-medium text-slate-100">{a.fullName}</td>
                <td className="px-3 py-2.5 text-slate-300">{a.email}</td>
                <td className="px-3 py-2.5">
                  <select
                    value={a.role}
                    disabled={busyId === a.id}
                    onChange={(e) => handleRoleChange(a, e.target.value)}
                    className="rounded-md border border-slate-700 bg-slate-950 px-1.5 py-1 text-[12px] text-slate-200 disabled:opacity-50"
                    title={a.isLastOwner ? "This user is the only owner -- role change to non-owner will be blocked" : undefined}
                  >
                    {VALID_ROLES.map((r) => (
                      <option key={r} value={r}>{r}</option>
                    ))}
                  </select>
                </td>
                <td className="px-3 py-2.5">
                  <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-medium ${a.isActive ? "bg-emerald-500/10 text-emerald-400" : "bg-slate-500/10 text-slate-400"}`}>
                    {a.isActive ? "Active" : "Deactivated"}
                  </span>
                </td>
                <td className="px-3 py-2.5 text-slate-500">{a.lastSignInAt ? new Date(a.lastSignInAt).toLocaleDateString() : "Never"}</td>
                <td className="px-3 py-2.5 text-slate-500">{new Date(a.createdAt).toLocaleDateString()}</td>
                <td className="px-4 py-2.5">
                  <div className="flex items-center justify-end gap-1.5">
                    {busyId === a.id ? (
                      <Loader2 className="size-4 animate-spin text-slate-500" />
                    ) : (
                      <>
                        <IconButton title="Edit Profile" onClick={() => setEditing(a)}><Pencil className="size-3.5" /></IconButton>
                        <IconButton title="Reset Password" onClick={() => handleReset(a)}><KeyRound className="size-3.5" /></IconButton>
                        <IconButton
                          title={a.isActive ? "Deactivate Access" : "Reactivate Access"}
                          onClick={() => handleToggleActive(a)}
                          danger={a.isActive}
                        >
                          {a.isActive ? <UserX className="size-3.5" /> : <UserCheck className="size-3.5" />}
                        </IconButton>
                      </>
                    )}
                  </div>
                </td>
              </tr>
            ))}
            {admins.length === 0 && (
              <tr>
                <td colSpan={7} className="px-4 py-8 text-center text-sm text-slate-500">No admins yet.</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {showAdd && <AddAdminDialog orgId={orgId} onClose={() => setShowAdd(false)} onCreated={(email, password) => { setShowAdd(false); setReveal({ email, password }); }} />}
      {editing && <EditAdminDialog orgId={orgId} admin={editing} onClose={() => setEditing(null)} />}
      {reveal && <TempPasswordReveal email={reveal.email} password={reveal.password} onClose={() => setReveal(null)} />}
    </div>
  );
}

function IconButton({ title, onClick, danger, children }: { title: string; onClick: () => void; danger?: boolean; children: React.ReactNode }) {
  return (
    <button
      type="button"
      title={title}
      onClick={onClick}
      className={`flex size-7 items-center justify-center rounded-md border border-slate-700 ${danger ? "text-red-400 hover:bg-red-500/10" : "text-slate-400 hover:bg-slate-800 hover:text-slate-200"}`}
    >
      {children}
    </button>
  );
}

function AddAdminDialog({ orgId, onClose, onCreated }: { orgId: string; onClose: () => void; onCreated: (email: string, password: string) => void }) {
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setSubmitting(true);
    setError(null);
    try {
      const { tempPassword, email } = await addCompanyAdmin(orgId, new FormData(e.currentTarget));
      onCreated(email, tempPassword);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not add admin.");
      setSubmitting(false);
    }
  }

  return (
    <Modal title="Add Admin" onClose={onClose}>
      <form onSubmit={handleSubmit} className="space-y-3">
        <div className="grid grid-cols-2 gap-3">
          <Field label="First Name"><input name="first_name" required className={inputClass} /></Field>
          <Field label="Last Name"><input name="last_name" required className={inputClass} /></Field>
        </div>
        <Field label="Email"><input name="email" type="email" required className={inputClass} /></Field>
        <Field label="Role">
          <select name="role" defaultValue="dispatcher" className={inputClass}>
            {VALID_ROLES.map((r) => <option key={r} value={r}>{r}</option>)}
          </select>
        </Field>
        <p className="text-[11px] text-slate-500">A temporary password will be generated and shown once after creation.</p>
        {error && <p className="text-[12.5px] text-red-400">{error}</p>}
        <div className="flex justify-end gap-2 pt-1">
          <button type="button" onClick={onClose} className="h-9 rounded-lg border border-slate-700 px-3 text-[12.5px] text-slate-300">Cancel</button>
          <button type="submit" disabled={submitting} className="flex h-9 items-center gap-1.5 rounded-lg bg-blue-500 px-3 text-[12.5px] font-semibold text-white disabled:opacity-60">
            {submitting && <Loader2 className="size-3.5 animate-spin" />} Add Admin
          </button>
        </div>
      </form>
    </Modal>
  );
}

function EditAdminDialog({ orgId, admin, onClose }: { orgId: string; admin: AdminRow; onClose: () => void }) {
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [resetResult, setResetResult] = useState<{ ok: boolean; text: string } | null>(null);

  async function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setSubmitting(true);
    setError(null);
    try {
      await updateAdminProfile(admin.id, orgId, new FormData(e.currentTarget));
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not save.");
    } finally {
      setSubmitting(false);
    }
  }

  async function handleSendResetEmail() {
    const result = await sendPasswordResetEmail(admin.id, orgId, admin.email);
    setResetResult({ ok: result.ok, text: result.ok ? "Reset email sent." : result.error ?? "Could not send." });
  }

  return (
    <Modal title="Edit Admin Profile" onClose={onClose}>
      <form onSubmit={handleSubmit} className="space-y-3">
        <Field label="Full Name"><input name="full_name" defaultValue={admin.fullName} required className={inputClass} /></Field>
        <Field label="Email"><input name="email" type="email" defaultValue={admin.email} className={inputClass} /></Field>
        <Field label="Phone"><input name="phone" type="tel" defaultValue={admin.phone ?? ""} className={inputClass} /></Field>
        {error && <p className="text-[12.5px] text-red-400">{error}</p>}
        <div className="flex items-center justify-between gap-2 border-t border-slate-800 pt-3">
          <button type="button" onClick={handleSendResetEmail} className="text-[11.5px] font-medium text-blue-400 hover:text-blue-300">
            Send Password Reset Email
          </button>
          <div className="flex gap-2">
            <button type="button" onClick={onClose} className="h-9 rounded-lg border border-slate-700 px-3 text-[12.5px] text-slate-300">Cancel</button>
            <button type="submit" disabled={submitting} className="flex h-9 items-center gap-1.5 rounded-lg bg-blue-500 px-3 text-[12.5px] font-semibold text-white disabled:opacity-60">
              {submitting && <Loader2 className="size-3.5 animate-spin" />} Save
            </button>
          </div>
        </div>
        {resetResult && <p className={`text-[11.5px] ${resetResult.ok ? "text-emerald-400" : "text-amber-400"}`}>{resetResult.text}</p>}
      </form>
    </Modal>
  );
}

function Modal({ title, onClose, children }: { title: string; onClose: () => void; children: React.ReactNode }) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4" onClick={onClose}>
      <div className="w-full max-w-md rounded-xl border border-slate-800 bg-slate-900 p-5 shadow-2xl" onClick={(e) => e.stopPropagation()}>
        <p className="mb-4 text-sm font-semibold text-slate-100">{title}</p>
        {children}
      </div>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1">
      <label className="text-[11px] font-medium uppercase tracking-wide text-slate-500">{label}</label>
      {children}
    </div>
  );
}
