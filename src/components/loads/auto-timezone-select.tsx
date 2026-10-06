"use client";

import { useEffect, useRef, useState } from "react";
import { COMMON_TIMEZONES } from "@/lib/timezone/iana";
import { suggestTimezone, zoneShortName, type TimezoneSuggestion } from "@/lib/timezone/us-location";
import { cn } from "@/lib/utils";

// Timezone dropdown for a stop on the New Load form that follows the stop's
// State and ZIP inputs (found by name in the same <form>) and pre-selects
// the matching zone. Plain uncontrolled inputs stay untouched; this only
// listens to their input/change events, including the ones the rate-con
// autofill dispatches.
//
// Once the dispatcher picks a zone by hand, the dropdown stops following
// the address (a person's choice always wins) and offers a one-click
// "use <suggested>" link if the address points somewhere else. Values set
// by the rate-con autofill are not treated as a hand pick.

export function AutoTimezoneSelect({
  name,
  stateName,
  zipName,
  defaultValue,
  label = "Timezone",
  selectClassName,
  labelClassName,
}: {
  name: string;
  stateName: string;
  zipName: string;
  defaultValue: string;
  label?: string;
  selectClassName?: string;
  labelClassName?: string;
}) {
  const ref = useRef<HTMLSelectElement>(null);
  const [value, setValue] = useState(defaultValue);
  const [suggestion, setSuggestion] = useState<TimezoneSuggestion | null>(null);
  const [manual, setManual] = useState(false);
  const manualRef = useRef(false);

  useEffect(() => {
    const form = ref.current?.form;
    if (!form) return;
    const read = (n: string) => (form.elements.namedItem(n) as HTMLInputElement | null)?.value ?? "";
    const update = () => {
      const s = suggestTimezone(read(stateName), read(zipName));
      setSuggestion(s);
      if (s && !manualRef.current) setValue(s.timezone);
    };
    const onField = (e: Event) => {
      const target = e.target as HTMLInputElement | null;
      if (target && (target.name === stateName || target.name === zipName)) update();
    };
    update(); // a value already in the inputs (browser restore, rate-con fill)
    form.addEventListener("input", onField);
    form.addEventListener("change", onField);
    return () => {
      form.removeEventListener("input", onField);
      form.removeEventListener("change", onField);
    };
  }, [stateName, zipName]);

  const pickedDiffers = manual && suggestion && suggestion.timezone !== value;

  return (
    <div className="min-w-0 space-y-1">
      <label htmlFor={name} className={labelClassName ?? "text-[12px] font-medium text-desktop-text"}>
        {label}
      </label>
      <select
        ref={ref}
        id={name}
        name={name}
        value={value}
        onChange={(e) => {
          setValue(e.target.value);
          // A real click/keypress (not the rate-con autofill's synthetic event) locks the choice.
          if (e.nativeEvent.isTrusted) {
            manualRef.current = true;
            setManual(true);
          }
        }}
        className={
          selectClassName ??
          "h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
        }
        data-auto-timezone={manual ? "manual" : suggestion ? suggestion.certainty : "default"}
      >
        {COMMON_TIMEZONES.map((tz) => (
          <option key={tz.value} value={tz.value}>
            {tz.label}
          </option>
        ))}
      </select>
      {pickedDiffers ? (
        <p className="text-[11px] text-desktop-text-muted">
          Set by hand.{" "}
          <button
            type="button"
            className="font-medium text-primary hover:underline"
            onClick={() => {
              manualRef.current = false;
              setManual(false);
              setValue(suggestion.timezone);
            }}
          >
            Use {zoneShortName(suggestion.timezone)} Time from the address
          </button>
        </p>
      ) : !manual && suggestion ? (
        <p className={cn("text-[11px]", suggestion.certainty === "check" ? "text-warning" : "text-desktop-text-muted")} aria-live="polite">
          {suggestion.reason}
        </p>
      ) : null}
    </div>
  );
}
