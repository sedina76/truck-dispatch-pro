"use client";

import { OTPInput, REGEXP_ONLY_DIGITS, type SlotProps } from "input-otp";
import { cn } from "@/lib/utils";

// Polished 6-digit OTP input (spec section 8): paste support, automatic
// focus progression, backspace navigation, numeric keyboard on mobile, and
// keyboard/screen-reader accessible -- all provided by input-otp's own
// underlying single hidden <input>, not hand-rolled per-box focus-juggling
// logic (spec section 8/26: "do not create fragile client-side-only
// verification logic" -- this component only COLLECTS the digits; the
// server/Supabase Auth remains the sole authority on whether they're
// correct, via verifySignupOtp() -> supabase.auth.verifyOtp()).
export function OtpInput({
  value,
  onChange,
  disabled,
  autoFocus,
  id,
}: {
  value: string;
  onChange: (value: string) => void;
  disabled?: boolean;
  autoFocus?: boolean;
  id?: string;
}) {
  return (
    <OTPInput
      id={id}
      value={value}
      onChange={onChange}
      maxLength={6}
      inputMode="numeric"
      pattern={REGEXP_ONLY_DIGITS}
      disabled={disabled}
      autoFocus={autoFocus}
      containerClassName="flex items-center justify-center gap-2"
      aria-label="6-digit verification code"
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
