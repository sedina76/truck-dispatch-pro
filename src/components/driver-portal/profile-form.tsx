"use client";

import { useState } from "react";
import { Loader2, CheckCircle2 } from "lucide-react";
import { updateMyDriverProfile } from "@/app/driver-portal/actions";

const inputClass = "h-11 w-full rounded-xl border border-border bg-background px-3 text-sm outline-none focus-visible:border-primary";

export function ProfileForm({
  phone,
  email,
  emergencyContactName,
  emergencyContactPhone,
}: {
  phone: string | null;
  email: string | null;
  emergencyContactName: string | null;
  emergencyContactPhone: string | null;
}) {
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setSaving(true);
    setError(null);
    setSaved(false);
    try {
      await updateMyDriverProfile(new FormData(e.currentTarget));
      setSaved(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not save.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-3">
      <Field label="Phone">
        <input name="phone" type="tel" inputMode="tel" defaultValue={phone ?? ""} className={inputClass} />
      </Field>
      <Field label="Email">
        <input name="email" type="email" defaultValue={email ?? ""} className={inputClass} />
      </Field>
      <Field label="Emergency Contact Name">
        <input name="emergency_contact_name" type="text" defaultValue={emergencyContactName ?? ""} className={inputClass} />
      </Field>
      <Field label="Emergency Contact Phone">
        <input name="emergency_contact_phone" type="tel" inputMode="tel" defaultValue={emergencyContactPhone ?? ""} className={inputClass} />
      </Field>

      {error && <p className="text-xs text-danger">{error}</p>}
      {saved && (
        <p className="flex items-center gap-1.5 text-xs text-success">
          <CheckCircle2 className="size-3.5" /> Saved.
        </p>
      )}

      <button type="submit" disabled={saving} className="flex h-12 w-full items-center justify-center gap-2 rounded-xl bg-primary text-sm font-semibold text-primary-foreground disabled:opacity-60">
        {saving && <Loader2 className="size-4 animate-spin" />}
        Save Changes
      </button>
    </form>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1">
      <label className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</label>
      {children}
    </div>
  );
}
