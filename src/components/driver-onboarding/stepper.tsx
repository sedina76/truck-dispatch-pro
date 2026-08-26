"use client";

import { usePathname } from "next/navigation";
import { Check } from "lucide-react";
import { cn } from "@/lib/utils";

// Phase 2Q.2B: Tax (W-9) is always listed here for a consistent step
// count/progress bar regardless of worker type -- the page itself (not
// the stepper, which has no data to decide with) shows "Not required for
// your role" and a plain Continue button when worker_type doesn't need a
// W-9 (Section I: never build a W-2 tax form here).
const STEPS = [
  { key: "personal", label: "Personal", href: "/driver-onboarding/personal" },
  { key: "license", label: "License", href: "/driver-onboarding/license" },
  { key: "medical-card", label: "Medical Card", href: "/driver-onboarding/medical-card" },
  { key: "employment", label: "Employment", href: "/driver-onboarding/employment" },
  { key: "tax-w9", label: "Tax (W-9)", href: "/driver-onboarding/tax-w9" },
  { key: "agreement", label: "Agreement", href: "/driver-onboarding/agreement" },
  { key: "review", label: "Review", href: "/driver-onboarding/review" },
];

// Mirrors src/components/carrier-onboarding/stepper.tsx exactly -- visual
// progress only, never gates navigation (every step's own server action
// re-validates on submit regardless of how the driver got there).
// Welcome/Complete sit outside the numbered sequence as bookends.
export function DriverOnboardingStepper() {
  const pathname = usePathname();
  const activeIndex = STEPS.findIndex((s) => pathname?.startsWith(s.href));
  if (pathname === "/driver-onboarding/welcome" || pathname === "/driver-onboarding/complete" || activeIndex === -1) return null;

  return (
    <div className="rounded-md border border-desktop-border bg-card p-3">
      <div className="flex items-center justify-between sm:hidden">
        <p className="text-[13px] font-medium text-desktop-text">
          Step {activeIndex + 1} of {STEPS.length}: {STEPS[activeIndex].label}
        </p>
        <div className="flex items-center gap-1">
          {STEPS.map((s, i) => (
            <span key={s.key} className={cn("size-1.5 rounded-full", i <= activeIndex ? "bg-primary" : "bg-muted")} />
          ))}
        </div>
      </div>
      <div className="hidden items-center sm:flex">
        {STEPS.map((s, i) => (
          <div key={s.key} className="flex flex-1 items-center last:flex-none">
            <div className="flex flex-col items-center gap-1">
              <div
                className={cn(
                  "flex size-6 shrink-0 items-center justify-center rounded-full text-[11px] font-semibold",
                  i < activeIndex ? "bg-success text-success-foreground" : i === activeIndex ? "bg-primary text-primary-foreground" : "bg-muted text-muted-foreground"
                )}
              >
                {i < activeIndex ? <Check className="size-3.5" /> : i + 1}
              </div>
              <span className={cn("text-[11px] font-medium", i === activeIndex ? "text-desktop-text" : "text-muted-foreground")}>{s.label}</span>
            </div>
            {i < STEPS.length - 1 && <div className={cn("mx-2 h-px flex-1", i < activeIndex ? "bg-success" : "bg-muted")} />}
          </div>
        ))}
      </div>
    </div>
  );
}
