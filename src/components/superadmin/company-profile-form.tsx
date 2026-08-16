"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { Loader2, AlertTriangle, Check } from "lucide-react";
import { updateCompanyProfile } from "@/app/(superadmin)/admin/companies/platform-actions";

const inputClass = "h-9 w-full rounded-lg border border-slate-700 bg-slate-950 px-2.5 text-[12.5px] text-slate-100 outline-none focus-visible:border-blue-500";
const labelClass = "text-[11px] font-medium uppercase tracking-wide text-slate-500";

export type OrgProfile = {
  id: string;
  name: string;
  slug: string;
  dba_name: string | null;
  business_phone: string | null;
  business_email: string | null;
  website: string | null;
  address_line1: string | null;
  city: string | null;
  state: string | null;
  postal_code: string | null;
  country: string | null;
  timezone: string | null;
};

// `redirectTo` distinguishes the two places this form is used: inside the
// Company Detail page's "Company Profile" tab (undefined -- stays on the
// tab, shows an inline "Saved." confirmation) vs. the dedicated
// /admin/companies/[id]/edit page (set -- redirects back to the detail
// page and refreshes its server-rendered data after a successful save).
export function CompanyProfileForm({ org, redirectTo }: { org: OrgProfile; redirectTo?: string }) {
  const router = useRouter();
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const [slugValue, setSlugValue] = useState(org.slug);
  const slugChanged = slugValue !== org.slug;

  async function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setSubmitting(true);
    setError(null);
    setSaved(false);
    try {
      await updateCompanyProfile(org.id, new FormData(e.currentTarget));
      setSaved(true);
      if (redirectTo) {
        router.push(redirectTo);
        router.refresh();
        return; // navigating away -- no need to reset `submitting`
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not save.");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="max-w-2xl space-y-4">
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <Field label="Company Name *"><input name="name" defaultValue={org.name} required className={inputClass} /></Field>
        <Field label="DBA">
          <input name="dba_name" defaultValue={org.dba_name ?? ""} className={inputClass} />
        </Field>
        <Field label="Slug *">
          <input name="slug" value={slugValue} onChange={(e) => setSlugValue(e.target.value)} required className={inputClass} />
        </Field>
        <Field label="Phone"><input name="business_phone" type="tel" defaultValue={org.business_phone ?? ""} className={inputClass} /></Field>
        <Field label="Email"><input name="business_email" type="email" defaultValue={org.business_email ?? ""} className={inputClass} /></Field>
        <Field label="Website"><input name="website" defaultValue={org.website ?? ""} className={inputClass} /></Field>
        <Field label="Address"><input name="address_line1" defaultValue={org.address_line1 ?? ""} className={inputClass} /></Field>
        <Field label="City"><input name="city" defaultValue={org.city ?? ""} className={inputClass} /></Field>
        <Field label="State"><input name="state" defaultValue={org.state ?? ""} className={inputClass} /></Field>
        <Field label="Postal Code"><input name="postal_code" defaultValue={org.postal_code ?? ""} className={inputClass} /></Field>
        <Field label="Country"><input name="country" defaultValue={org.country ?? "US"} className={inputClass} /></Field>
        <Field label="Timezone"><input name="timezone" defaultValue={org.timezone ?? "America/Chicago"} className={inputClass} /></Field>
      </div>

      {slugChanged && (
        <p className="flex items-start gap-1.5 rounded-lg border border-amber-500/20 bg-amber-500/5 px-3 py-2 text-[12px] text-amber-300">
          <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
          Changing the slug changes this company&apos;s URL identifier. It must remain unique -- a conflicting slug will be rejected with a clear error, not silently overwritten.
        </p>
      )}

      {error && <p className="text-[12.5px] text-red-400">{error}</p>}
      {saved && !submitting && (
        <p className="flex items-center gap-1.5 text-[12.5px] text-emerald-400">
          <Check className="size-3.5" /> Saved.
        </p>
      )}

      <div className="flex items-center gap-2">
        {redirectTo && (
          <Link href={redirectTo} className="flex h-10 items-center rounded-lg border border-slate-700 px-4 text-[13px] font-medium text-slate-300 hover:bg-slate-800">
            Cancel
          </Link>
        )}
        <button type="submit" disabled={submitting} className="flex h-10 items-center gap-1.5 rounded-lg bg-blue-500 px-4 text-[13px] font-semibold text-white disabled:opacity-60">
          {submitting && <Loader2 className="size-4 animate-spin" />} Save Changes
        </button>
      </div>
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
