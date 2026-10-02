"use client";

import { useEffect } from "react";
import { keyWouldStepNumber, wheelWouldChangeNumber } from "@/lib/forms/number-wheel";
import { moneyChange, moneyChangeMessage, type MoneyChange } from "@/lib/forms/money-change";

// Mounted once in the root layout: every number field in the app (rates,
// amounts, miles, percentages) changes only when a value is typed -- never
// by arrow keys or scrolling. See lib/forms/number-wheel.ts.
export function NumberWheelGuard() {
  useEffect(() => {
    function onWheel(e: WheelEvent) {
      const target = e.target as HTMLInputElement | null;
      // blur (not preventDefault): the page still scrolls, the value doesn't change.
      if (wheelWouldChangeNumber(target, document.activeElement)) target?.blur();
    }
    function onKeyDown(e: KeyboardEvent) {
      if (keyWouldStepNumber(e.target as HTMLInputElement | null, e.key)) e.preventDefault();
    }
    // Second net: a changed guarded amount (FormField confirmChange) must be
    // confirmed. Runs in the capture phase, before React's form action, so
    // "Cancel" stops the save entirely.
    function onSubmit(e: SubmitEvent) {
      const form = e.target as HTMLFormElement | null;
      if (!form?.querySelectorAll) return;
      const changes = Array.from(form.querySelectorAll<HTMLInputElement>("input[data-confirm-change]"))
        .map((el) => moneyChange(el.dataset.confirmChange ?? "Amount", el.dataset.originalValue, el.value))
        .filter((c): c is MoneyChange => c !== null);
      if (changes.length && !window.confirm(moneyChangeMessage(changes))) {
        e.preventDefault();
        e.stopImmediatePropagation();
      }
    }
    document.addEventListener("wheel", onWheel, { capture: true, passive: true });
    document.addEventListener("keydown", onKeyDown, { capture: true });
    document.addEventListener("submit", onSubmit, { capture: true });
    return () => {
      document.removeEventListener("wheel", onWheel, { capture: true });
      document.removeEventListener("keydown", onKeyDown, { capture: true });
      document.removeEventListener("submit", onSubmit, { capture: true });
    };
  }, []);
  return null;
}
