"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { createCompany } from "@/app/(superadmin)/admin/companies/platform-actions";
import { TempPasswordReveal } from "./temp-password-reveal";

const inputClass = "h-10 w-full rounded-lg border border-slate-700 bg-slate-950 px-3 text-[13px] text-slate-100 outline-none focus-visible:border-blue-500";
const labelClass = "text-[11px] font-medium uppercase tracking-wide text-slate-500";

export function AddCompanyForm({ plans }: { plans: { id: string; name: string; monthly_price_cents: number }[] }) {
  const router = useRouter();
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<{ orgId: string; tempPassword: string; adminEmail: string } | null>(null);

  async function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setSubmitting(true);
    setError(null);
    try {
      const res = await createCompany(new FormData(e.currentTarget));
      setResult(res);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not create company.");
    } finally {
      setSubmitting(false);
    }
  }

  if (result) {
    return (
      <TempPasswordReveal
        email={result.adminEmail}
        password={result.tempPassword}
        onClose={() => router.push(`/admin/companies/${result.orgId}`)}
      />
    );
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-6">
      <div className="rounded-xl border border-slate-800 bg-slate-900/60 p-5">
        <p className="mb-4 text-sm font-semibold text-slate-100">Company</p>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Field label="Company Name *"><input name="company_name" required className={inputClass} /></Field>
          <Field label="Slug (auto-generated if blank)"><input name="slug" className={inputClass} placeholder="acme-logistics" /></Field>
          <Field label="Contact Email"><input name="contact_email" type="email" className={inputClass} /></Field>
          <Field label="Phone"><input name="phone" type="tel" className={inputClass} /></Field>
          <Field label="Address"><input name="address" className={inputClass} /></Field>
          <Field label="Timezone"><input name="timezone" defaultValue="America/Chicago" className={inputClass} /></Field>
        </div>
      </div>

      <div className="rounded-xl border border-slate-800 bg-slate-900/60 p-5">
        <p className="mb-1 text-sm font-semibold text-slate-100">Initial Subscription (optional)</p>
        <p className="mb-4 text-[12px] text-slate-500">Leave blank to create the company with no subscription yet.</p>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Field label="Plan">
            <select name="plan_id" className={inputClass} defaultValue="">
              <option value="">No plan</option>
              {plans.map((p) => (
                <option key={p.id} value={p.id}>{p.name} -- ${(p.monthly_price_cents / 100).toFixed(2)}/mo</option>
              ))}
            </select>
          </Field>
          <Field label="Status">
            <select name="status" className={inputClass} defaultValue="trialing">
              <option value="trialing">Trialing</option>
              <option value="active">Active</option>
            </select>
          </Field>
        </div>
      </div>

      <div className="rounded-xl border border-slate-800 bg-slate-900/60 p-5">
        <p className="mb-4 text-sm font-semibold text-slate-100">Primary Admin</p>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Field label="First Name *"><input name="admin_first_name" required className={inputClass} /></Field>
          <Field label="Last Name *"><input name="admin_last_name" required className={inputClass} /></Field>
          <Field label="Email *"><input name="admin_email" type="email" required className={inputClass} /></Field>
        </div>
        <p className="mt-3 text-[11.5px] text-slate-500">
          A temporary password will be generated and shown once after the company is created. No email provider is configured on this instance, so no invitation email will be sent.
        </p>
      </div>

      {error && <p className="text-sm text-red-400">{error}</p>}

      <button
        type="submit"
        disabled={submitting}
        className="flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-blue-500 text-sm font-semibold text-white hover:bg-blue-600 disabled:opacity-60 sm:w-auto sm:px-6"
      >
        {submitting && <Loader2 className="size-4 animate-spin" />}
        Create Company
      </button>
    </form>
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
