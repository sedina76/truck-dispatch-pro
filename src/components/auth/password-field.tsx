"use client";

import { useState } from "react";
import { Eye, EyeOff } from "lucide-react";
import { AuthInput } from "@/components/auth/auth-input";
import { PasswordStrength } from "@/components/ui/password-strength";

export function PasswordField({
  id,
  name,
  label,
  autoComplete,
  required = true,
  disabled,
  value,
  onChange,
  strength = false,
  dark = false,
}: {
  id: string;
  name: string;
  label: string;
  autoComplete: string;
  required?: boolean;
  disabled?: boolean;
  value: string;
  onChange: (value: string) => void;
  strength?: boolean;
  dark?: boolean;
}) {
  const [show, setShow] = useState(false);

  return (
    <div className="space-y-1.5">
      <label htmlFor={id} className={dark ? "text-sm font-medium text-white/90" : "text-sm font-medium text-[#3a3a34]"}>
        {label}
      </label>
      <div className="relative">
        <AuthInput
          id={id}
          name={name}
          type={show ? "text" : "password"}
          autoComplete={autoComplete}
          minLength={8}
          required={required}
          disabled={disabled}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          className="pr-9"
          dark={dark}
        />
        <button
          type="button"
          onClick={() => setShow((v) => !v)}
          className={dark ? "absolute inset-y-0 right-1 flex w-10 items-center justify-center text-white/45 hover:text-white/80" : "absolute inset-y-0 right-0 flex w-9 items-center justify-center text-[#b0b0a8] hover:text-[#6b6b64]"}
          aria-label={show ? "Hide password" : "Show password"}
          tabIndex={-1}
        >
          {show ? <EyeOff className="size-4" /> : <Eye className="size-4" />}
        </button>
      </div>
      {strength && <PasswordStrength password={value} />}
    </div>
  );
}
