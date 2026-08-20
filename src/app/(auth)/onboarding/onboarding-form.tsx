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
        <label htmlFor="name" className="text-sm font-medium text-[#3a3a34]">
          Company Name
        </label>
        <AuthInput id="name" name="name" type="text" placeholder="Northbound Logistics" required disabled={pending} />
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-1.5">
          <label htmlFor="dotNumber" className="text-sm font-medium text-[#3a3a34]">
            DOT Number
          </label>
          <AuthInput id="dotNumber" name="dotNumber" type="text" inputMode="numeric" disabled={pending} />
        </div>
        <div className="space-y-1.5">
          <label htmlFor="mcNumber" className="text-sm font-medium text-[#3a3a34]">
            MC Number
          </label>
          <AuthInput id="mcNumber" name="mcNumber" type="text" inputMode="numeric" disabled={pending} />
        </div>
      </div>

      <div className="space-y-1.5">
        <label htmlFor="businessPhone" className="text-sm font-medium text-[#3a3a34]">
          Phone
        </label>
        <AuthInput id="businessPhone" name="businessPhone" type="tel" inputMode="tel" autoComplete="tel" disabled={pending} />
      </div>

      <div className="space-y-1.5">
        <label htmlFor="timezone" className="text-sm font-medium text-[#3a3a34]">
          Time Zone
        </label>
        <select
          id="timezone"
          name="timezone"
          disabled={pending}
          defaultValue=""
          className="flex h-10 w-full rounded-md border border-[#d8d8d2] bg-white px-2.5 text-[13px] text-[#1a1a18] shadow-sm outline-none focus-visible:border-[#1c54b8] focus-visible:ring-2 focus-visible:ring-[#1c54b8]/15 disabled:cursor-not-allowed disabled:opacity-50"
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
        <p role="alert" aria-live="polite" className="text-sm text-danger">
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
