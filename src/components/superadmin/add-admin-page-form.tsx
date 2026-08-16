"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { Loader2 } from "lucide-react";
import { addCompanyAdmin } from "@/app/(superadmin)/admin/companies/platform-actions";
import { TempPasswordReveal } from "./temp-password-reveal";

const VALID_ROLES = ["owner", "admin", "dispatcher", "accountant", "driver", "viewer"];
const inputClass = "h-9 w-full rounded-lg border border-slate-700 bg-slate-950 px-2.5 text-[12.5px] text-slate-100 outline-none focus-visible:border-blue-500";
const labelClass = "text-[11px] font-medium uppercase tracking-wide text-slate-500";

// Page-level counterpart of CompanyAdminsPanel's AddAdminDialog -- same
// addCompanyAdmin server action (create auth.users -> platform_assign_
// user_to_org -> log_activity, with rollback-on-failure), just rendered as
// a standalone page with Cancel/Create instead of a modal, per the
// dedicated /admin/companies/[id]/admins/new route.
export function AddAdminPageForm({ orgId, backHref }: { orgId: string; backHref: string }) {
  const router = useRouter();
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [reveal, setReveal] = useState<{ email: string; password: string } | null>(null);

  async function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setSubmitting(true);
    setError(null);
    try {
      const { tempPassword, email } = await addCompanyAdmin(orgId, new FormData(e.currentTarget));
      setReveal({ email, password: tempPassword });
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not add admin.");
      setSubmitting(false);
    }
  }

  function handleRevealClosed() {
    router.push(backHref);
    router.refresh();
  }

  return (
    <>
      <form onSubmit={handleSubmit} className="max-w-lg space-y-4">
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Field label="First Name *"><input name="first_name" required className={inputClass} /></Field>
          <Field label="Last Name *"><input name="last_name" required className={inputClass} /></Field>
        </div>
        <Field label="Email *"><input name="email" type="email" required className={inputClass} /></Field>
        <Field label="Phone"><input name="phone" type="tel" className={inputClass} /></Field>
        <Field label="Role">
          <select name="role" defaultValue="dispatcher" className={inputClass}>
            {VALID_ROLES.map((r) => (
              <option key={r} value={r}>{r}</option>
            ))}
          </select>
        </Field>

        <p className="text-[11.5px] text-slate-500">
          A Supabase Auth account and profile will be created and linked to this company with the selected role. A
          temporary password will be generated and shown once, immediately after creation -- it is never stored in
          plaintext and can&apos;t be retrieved again afterward.
        </p>

        {error && <p className="text-[12.5px] text-red-400">{error}</p>}

        <div className="flex items-center gap-2">
          <Link href={backHref} className="flex h-10 items-center rounded-lg border border-slate-700 px-4 text-[13px] font-medium text-slate-300 hover:bg-slate-800">
            Cancel
          </Link>
          <button type="submit" disabled={submitting} className="flex h-10 items-center gap-1.5 rounded-lg bg-blue-500 px-4 text-[13px] font-semibold text-white disabled:opacity-60">
            {submitting && <Loader2 className="size-4 animate-spin" />} Create Admin
          </button>
        </div>
      </form>

      {reveal && <TempPasswordReveal email={reveal.email} password={reveal.password} onClose={handleRevealClosed} />}
    </>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1">
      <label className={labelClass}>{label}</label>
      {children}
    </div>
  );
}
