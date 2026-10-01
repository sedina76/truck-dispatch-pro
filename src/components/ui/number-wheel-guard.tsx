"use client";

import { useEffect } from "react";
import { keyWouldStepNumber, wheelWouldChangeNumber } from "@/lib/forms/number-wheel";

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
    document.addEventListener("wheel", onWheel, { capture: true, passive: true });
    document.addEventListener("keydown", onKeyDown, { capture: true });
    return () => {
      document.removeEventListener("wheel", onWheel, { capture: true });
      document.removeEventListener("keydown", onKeyDown, { capture: true });
    };
  }, []);
  return null;
}
