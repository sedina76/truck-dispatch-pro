"use client";

import { useActionState } from "react";
import { Check } from "lucide-react";
import { createOrganization, type CreateOrganizationState } from "@/lib/supabase/actions";
import { COMMON_TIMEZONES } from "@/lib/timezone/iana";
import { AuthInput } from "@/components/auth/auth-input";
import { AuthButton } from "@/components/auth/auth-button";

const initialState: CreateOrganizationState = { error: null };

export function OnboardingForm() {
  const [state, formAction, pending] = useActionState(createOrganization, initialState);

  return (
    <form action={formAction} className="space-y-4" aria-busy={pending}>
      <div className="space-y-1.5">
        <label htmlFor="name" className="text-sm font-medium text-white/90">
          Company Name
        </label>
        <AuthInput dark id="name" name="name" type="text" placeholder="Northbound Logistics" required disabled={pending} />
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-1.5">
          <label htmlFor="dotNumber" className="text-sm font-medium text-white/90">
            DOT Number
          </label>
          <AuthInput dark id="dotNumber" name="dotNumber" type="text" inputMode="numeric" disabled={pending} />
        </div>
        <div className="space-y-1.5">
          <label htmlFor="mcNumber" className="text-sm font-medium text-white/90">
            MC Number
          </label>
          <AuthInput dark id="mcNumber" name="mcNumber" type="text" inputMode="numeric" disabled={pending} />
        </div>
      </div>

      <div className="space-y-1.5">
        <label htmlFor="businessPhone" className="text-sm font-medium text-white/90">
          Phone
        </label>
        <AuthInput dark id="businessPhone" name="businessPhone" type="tel" inputMode="tel" autoComplete="tel" disabled={pending} />
      </div>

      <div className="space-y-1.5">
        <label htmlFor="timezone" className="text-sm font-medium text-white/90">
          Time Zone
        </label>
        <select
          id="timezone"
          name="timezone"
          disabled={pending}
          defaultValue=""
          className="flex h-10 w-full rounded-md border border-white/20 bg-white/[0.045] px-2.5 text-[13px] text-white [&>option]:bg-[#081426] [&>option]:text-white shadow-sm outline-none focus-visible:border-[#2680ff] focus-visible:ring-2 focus-visible:ring-[#2680ff]/15 disabled:cursor-not-allowed disabled:opacity-50"
        >
          <option value="">Select a time zone</option>
          {COMMON_TIMEZONES.map((tz) => (
            <option key={tz.value} value={tz.value}>
              {tz.label}
            </option>
          ))}
        </select>
      </div>

      {state.error && (
        <p role="alert" aria-live="polite" className="text-sm text-red-300">
          {state.error}
        </p>
      )}

      <AuthButton type="submit" disabled={pending}>
        {pending ? (
          "Creating…"
        ) : (
          <>
            <Check className="size-4" />
            Create Organization
          </>
        )}
      </AuthButton>
    </form>
  );
}
