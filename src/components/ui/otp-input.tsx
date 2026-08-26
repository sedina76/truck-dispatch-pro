"use client";

import { OTPInput, REGEXP_ONLY_DIGITS, type SlotProps } from "input-otp";
import { cn } from "@/lib/utils";

// Polished, length-configurable OTP input: paste support, automatic focus
// progression, backspace navigation, numeric keyboard on mobile, and
// keyboard/screen-reader accessible -- all provided by input-otp's own
// underlying single hidden <input>, not hand-rolled per-box focus-juggling
// logic (this component only COLLECTS the digits; the server/Supabase
// Auth remains the sole authority on whether they're correct, via
// verifySignupOtp() -> supabase.auth.verifyOtp()).
//
// Auth OTP length mismatch repair: `length` defaults to 6 (Supabase
// Auth's own default) rather than being hard-coded, since this component
// has exactly one caller today (the signup verify-email form) but nothing
// stops a second one (e.g. a future phone/MFA OTP step) from needing a
// different length -- the caller now states its own length explicitly
// instead of this component assuming everyone's project is configured
// the same way. Callers should source their length from a single named
// constant (see src/lib/auth/otp.ts for the signup flow's) rather than a
// second hard-coded number, for the same reason.
export function OtpInput({
  value,
  onChange,
  disabled,
  autoFocus,
  id,
  length = 6,
}: {
  value: string;
  onChange: (value: string) => void;
  disabled?: boolean;
  autoFocus?: boolean;
  id?: string;
  length?: number;
}) {
  return (
    <OTPInput
      id={id}
      value={value}
      onChange={onChange}
      maxLength={length}
      inputMode="numeric"
      pattern={REGEXP_ONLY_DIGITS}
      disabled={disabled}
      autoFocus={autoFocus}
      containerClassName="flex flex-wrap items-center justify-center gap-2"
      aria-label={`${length}-digit verification code`}
      render={({ slots }) => (
        <>
          {slots.map((slot, i) => (
            <OtpSlot key={i} {...slot} />
          ))}
        </>
      )}
    />
  );
}

function OtpSlot({ char, isActive, hasFakeCaret }: SlotProps) {
  return (
    <div
      className={cn(
        // Fixed light colors, not the theme-reactive border-desktop-border/
        // bg-card/text-foreground -- this component is used exclusively
        // inside AuthCard's deliberately-fixed white surface (see that
        // component's header comment); a theme-reactive slot would render
        // dark-on-dark for an OS-dark-mode visitor.
        "relative flex size-11 items-center justify-center rounded-md border text-lg font-semibold tabular-nums shadow-sm transition-colors sm:size-12",
        "border-[#d8d8d2] bg-white text-[#1a1a18]",
        isActive && "border-[#1c54b8] ring-2 ring-[#1c54b8]/20"
      )}
    >
      {char}
      {hasFakeCaret && (
        <div className="pointer-events-none absolute inset-0 flex items-center justify-center motion-reduce:hidden">
          <div className="h-5 w-px animate-pulse bg-[#1a1a18]" />
        </div>
      )}
    </div>
  );
}
