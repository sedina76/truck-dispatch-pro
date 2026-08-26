"use client";

import { usePathname } from "next/navigation";
import { Check } from "lucide-react";
import { cn } from "@/lib/utils";

const STEPS = [
  { key: "company", label: "Company", href: "/carrier-onboarding/company" },
  { key: "w9", label: "Tax Info", href: "/carrier-onboarding/w9" },
  { key: "equipment", label: "Equipment", href: "/carrier-onboarding/equipment" },
  { key: "documents", label: "Documents", href: "/carrier-onboarding/documents" },
  { key: "agreement", label: "Agreement", href: "/carrier-onboarding/agreement" },
  { key: "review", label: "Review", href: "/carrier-onboarding/review" },
];

// Visual progress only -- never gates navigation itself (every step's own
// server action re-validates on submit regardless of how the carrier got
// there). Welcome/Completion intentionally sit outside this 1-5 sequence
// (spec section 8's flow treats them as bookends, not numbered steps).
export function OnboardingStepper() {
  const pathname = usePathname();
  const activeIndex = STEPS.findIndex((s) => pathname?.startsWith(s.href));
  if (pathname === "/carrier-onboarding/welcome" || pathname === "/carrier-onboarding/complete" || activeIndex === -1) return null;

  return (
    <div className="rounded-md border border-desktop-border bg-card p-3">
      {/* Mobile: compact dots + current label. */}
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
      {/* Desktop/tablet: full labeled stepper. */}
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
