import Link from "next/link";
import { CheckCircle2, Download, Eye } from "lucide-react";
import { createMyW9Draft, getMyW9 } from "../../actions";
import { W9Form } from "./w9-form";

// Phase 2N.2 -- carrier onboarding W-9 step. NOT YET LIVE (depends on
// migration 0099, not applied). Placed between Company and Equipment in
// the stepper (see components/carrier-onboarding/stepper.tsx) -- taxpayer
// identity naturally follows company info and precedes equipment/document
// collection.
export default async function OnboardingW9Page() {
  let w9 = await getMyW9();
  if (!w9) {
    const created = await createMyW9Draft();
    if (!created.ok) {
      return (
        <div className="rounded-md border border-desktop-border bg-card p-4 sm:p-5">
          <h2 className="text-[15px] font-semibold text-desktop-text">Taxpayer Information (W-9)</h2>
          <p className="mt-2 text-[13px] text-muted-foreground">{created.error}</p>
        </div>
      );
    }
    w9 = await getMyW9();
  }
  if (!w9) return null;

  if (w9.status === "completed" || w9.status === "superseded") {
    return (
      <div className="space-y-3">
        <div className="rounded-md border border-desktop-border bg-card p-4 sm:p-5">
          <div className="flex items-center gap-2 text-desktop-success">
            <CheckCircle2 className="size-5 shrink-0" />
            <h2 className="text-[15px] font-semibold text-desktop-text">Form W-9 -- Completed</h2>
          </div>
          <p className="mt-1 text-[12px] text-muted-foreground">
            Your taxpayer identification has been certified and recorded. Taxpayer ID on file: {w9.tin_type === "ein" ? "XX-XXX" : "XXX-XX-"}
            {w9.tin_last4}.
          </p>
          <div className="mt-3 flex flex-wrap gap-2">
            <Link href={`/carrier-onboarding/w9/${w9.id}/pdf`} target="_blank" className="inline-flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border px-3 text-[12.5px] font-medium hover:bg-muted">
              <Eye className="size-3.5" /> View W-9
            </Link>
            <Link href={`/carrier-onboarding/w9/${w9.id}/pdf?download=1`} className="inline-flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border px-3 text-[12.5px] font-medium hover:bg-muted">
              <Download className="size-3.5" /> Download
            </Link>
          </div>
        </div>
        <div className="flex justify-end">
          <Link href="/carrier-onboarding/equipment" className="inline-flex h-9 items-center rounded-sm bg-primary px-4 text-[13.5px] font-medium text-primary-foreground shadow-elevation-1 transition-colors hover:bg-primary-hover">
            Continue to Equipment
          </Link>
        </div>
      </div>
    );
  }

  if (w9.status === "failed") {
    return (
      <div className="rounded-md border border-warning/40 bg-warning/10 p-4 text-[13px] text-desktop-text">
        We could not generate your W-9 document. Please contact your dispatch company to start a new one.
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <div className="rounded-md border border-desktop-border bg-card p-4 sm:p-5">
        <h2 className="text-[15px] font-semibold text-desktop-text">Form W-9 (Rev. March 2024)</h2>
        <p className="mt-1 text-[12px] text-muted-foreground">Request for Taxpayer Identification Number and Certification.</p>
        <W9Form w9={w9} />
      </div>
    </div>
  );
}
