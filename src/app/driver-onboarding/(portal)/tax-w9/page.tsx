import Link from "next/link";
import { CheckCircle2 } from "lucide-react";
import { getMyDriverApplication, getMyDriverW9, createMyDriverW9Draft } from "../../actions";
import { workerTypeRequiresW9, type DriverWorkerType } from "@/lib/driver-w9/types";
import { DriverW9Form } from "./driver-w9-form";

// Phase 2Q.2B -- Tax (W-9) step. Required only for 1099-style workers
// (independent_contractor/owner_operator); a company_driver (W-2) sees a
// short "not required" screen and a plain Continue -- no W-2 tax form is
// built here (Section I).
export default async function DriverOnboardingTaxW9Page() {
  const application = await getMyDriverApplication();
  if (!application) return null;

  if (!workerTypeRequiresW9(application.worker_type as DriverWorkerType | null)) {
    return (
      <div className="space-y-3 rounded-md border border-desktop-border bg-card p-4 text-center sm:p-8">
        <CheckCircle2 className="mx-auto size-7 text-muted-foreground" />
        <div>
          <h2 className="text-[15px] font-semibold text-desktop-text">Tax (W-9)</h2>
          <p className="mx-auto mt-2 max-w-sm text-[13px] text-muted-foreground">Not required for your role.</p>
        </div>
        <Link
          href="/driver-onboarding/agreement"
          className="inline-flex h-11 items-center rounded-sm bg-primary px-5 text-[14px] font-medium text-primary-foreground shadow-elevation-1 transition-colors hover:bg-primary-hover"
        >
          Continue
        </Link>
      </div>
    );
  }

  let w9 = await getMyDriverW9();
  if (!w9) {
    const created = await createMyDriverW9Draft();
    if (!created.ok) {
      return (
        <div className="rounded-md border border-desktop-border bg-card p-4 sm:p-5">
          <h2 className="text-[15px] font-semibold text-desktop-text">Tax (W-9)</h2>
          <p className="mt-2 text-[13px] text-muted-foreground">{created.error}</p>
        </div>
      );
    }
    w9 = await getMyDriverW9();
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
        </div>
        <div className="flex justify-end">
          <Link href="/driver-onboarding/agreement" className="inline-flex h-9 items-center rounded-sm bg-primary px-4 text-[13.5px] font-medium text-primary-foreground shadow-elevation-1 transition-colors hover:bg-primary-hover">
            Continue to Agreement
          </Link>
        </div>
      </div>
    );
  }

  if (w9.status === "failed") {
    return (
      <div className="rounded-md border border-warning/40 bg-warning/10 p-4 text-[13px] text-desktop-text">
        We could not generate your W-9 document. Please contact the company that invited you to start a new one.
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <div className="rounded-md border border-desktop-border bg-card p-4 sm:p-5">
        <h2 className="text-[15px] font-semibold text-desktop-text">Form W-9 (Rev. March 2024)</h2>
        <p className="mt-1 text-[12px] text-muted-foreground">Request for Taxpayer Identification Number and Certification.</p>
        <DriverW9Form w9={w9} />
      </div>
    </div>
  );
}
