"use client";

import { useState } from "react";

// Accepts digits-only input and auto-formats to XXX-XX-XXXX as the user
// types. Confirm-SSN uses setCustomValidity so the browser's native form
// validation blocks submission on a mismatch -- no custom submit-handling
// JS required, and it degrades safely (the server re-validates match/format
// independently in createDriver, since client-side validation is never
// trustworthy on its own).
function formatSsn(raw: string) {
  const digits = raw.replace(/\D/g, "").slice(0, 9);
  if (digits.length <= 3) return digits;
  if (digits.length <= 5) return `${digits.slice(0, 3)}-${digits.slice(3)}`;
  return `${digits.slice(0, 3)}-${digits.slice(3, 5)}-${digits.slice(5)}`;
}

export function SsnConfirmFields({ required = false }: { required?: boolean }) {
  const [ssn, setSsn] = useState("");
  const [confirmSsn, setConfirmSsn] = useState("");

  function syncConfirmValidity(next: string, ssnValue: string) {
    // Only enforce the match once both fields have something -- an empty
    // confirm field should fail on `required` alone, not a stale mismatch
    // message from before the user started typing there.
    if (next.length > 0 && next !== ssnValue) {
      return "SSNs do not match.";
    }
    return "";
  }

  return (
    <>
      <div className="space-y-1.5">
        <label htmlFor="ssn" className="text-sm font-medium text-foreground">
          Social Security Number
          {required && <span className="text-danger"> *</span>}
        </label>
        <input
          id="ssn"
          name="ssn"
          type="text"
          inputMode="numeric"
          autoComplete="off"
          placeholder="XXX-XX-XXXX"
          required={required}
          pattern="\d{3}-\d{2}-\d{4}"
          title="Format: XXX-XX-XXXX"
          value={ssn}
          onChange={(e) => {
            const formatted = formatSsn(e.target.value);
            setSsn(formatted);
            e.target.setCustomValidity("");
          }}
          className="h-10 w-full rounded-lg border border-border bg-card px-3.5 text-sm shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
        />
      </div>

      <div className="space-y-1.5">
        <label htmlFor="confirm_ssn" className="text-sm font-medium text-foreground">
          Confirm Social Security Number
          {required && <span className="text-danger"> *</span>}
        </label>
        <input
          id="confirm_ssn"
          name="confirm_ssn"
          type="text"
          inputMode="numeric"
          autoComplete="off"
          placeholder="XXX-XX-XXXX"
          required={required || ssn.length > 0}
          value={confirmSsn}
          onChange={(e) => {
            const formatted = formatSsn(e.target.value);
            setConfirmSsn(formatted);
            e.target.setCustomValidity(syncConfirmValidity(formatted, ssn));
          }}
          onBlur={(e) => e.target.setCustomValidity(syncConfirmValidity(confirmSsn, ssn))}
          className="h-10 w-full rounded-lg border border-border bg-card px-3.5 text-sm shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
        />
      </div>
    </>
  );
}
