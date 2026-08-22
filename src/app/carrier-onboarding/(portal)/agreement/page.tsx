import Link from "next/link";
import { CheckCircle2, Download, Eye } from "lucide-react";
import { getAgreementsForSigning, getMyRequiredAgreementReadiness } from "../../actions";
import { AgreementForm } from "./agreement-form";

export default async function OnboardingAgreementPage() {
  const [signings, readiness] = await Promise.all([getAgreementsForSigning(), getMyRequiredAgreementReadiness()]);

  if (!readiness.initialized) {
    return (
      <div className="rounded-md border border-desktop-border bg-card p-4 sm:p-5">
        <h2 className="text-[15px] font-semibold text-desktop-text">Dispatch Agreement</h2>
        <p className="mt-2 text-[13px] text-muted-foreground">
          Your required agreements are being prepared. Please try again shortly or contact your dispatch company.
        </p>
      </div>
    );
  }

  if (readiness.requirements.length === 0 && signings.length === 0) {
    return <div className="space-y-3"><div className="rounded-md border border-desktop-border bg-card p-4 sm:p-5"><h2 className="text-[15px] font-semibold text-desktop-text">Dispatch Agreement</h2><p className="mt-2 text-[13px] text-muted-foreground">No agreement is required for this onboarding application.</p></div><div className="flex justify-end"><Link href="/carrier-onboarding/review" className="inline-flex h-9 items-center rounded-sm bg-primary px-4 text-[13.5px] font-medium text-primary-foreground">Continue to Review</Link></div></div>;
  }

  const missingRequiredSigning = readiness.requirements.some((requirement) => !requirement.signingId);

  return (
    <div className="space-y-3">
      {missingRequiredSigning && <div className="rounded-md border border-warning/40 bg-warning/10 p-4 text-[13px] text-desktop-text">An agreement required for your onboarding is still being prepared by our office.</div>}
      {signings.map((signing) =>
        signing.status === "completed" ? (
          <div key={signing.signingId} className="rounded-md border border-desktop-border bg-card p-4 sm:p-5">
            <div className="flex items-center gap-2 text-desktop-success">
              <CheckCircle2 className="size-5 shrink-0" />
              <h2 className="text-[15px] font-semibold text-desktop-text">{signing.templateName} -- Signed</h2>
            </div>
            <p className="mt-1 text-[12px] text-muted-foreground">Version {signing.templateVersion}. No further action is needed for this agreement.</p>
            {signing.generatedDocumentId && signing.documentGenerationStatus === "generated" ? (
              <div className="mt-3 flex flex-wrap gap-2">
                <Link href={`/carrier-onboarding/agreement/${signing.signingId}/pdf`} target="_blank" className="inline-flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border px-3 text-[12.5px] font-medium hover:bg-muted"><Eye className="size-3.5" /> View Signed Agreement</Link>
                <Link href={`/carrier-onboarding/agreement/${signing.signingId}/pdf?download=1`} className="inline-flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border px-3 text-[12.5px] font-medium hover:bg-muted"><Download className="size-3.5" /> Download</Link>
              </div>
            ) : <p className="mt-3 text-[12.5px] text-muted-foreground">Your signed agreement is being prepared.</p>}
          </div>
        ) : (
          <div key={signing.signingId} className="rounded-md border border-desktop-border bg-card p-4 sm:p-5">
            <h2 className="text-[15px] font-semibold text-desktop-text">{signing.templateName}</h2>
            <p className="mt-0.5 text-[12px] text-muted-foreground">Version {signing.templateVersion}</p>
            <AgreementForm signing={signing} />
          </div>
        )
      )}

      {readiness.ready && <div className="flex justify-end">
        <Link
          href="/carrier-onboarding/review"
          className="inline-flex h-9 items-center rounded-sm bg-primary px-4 text-[13.5px] font-medium text-primary-foreground shadow-elevation-1 transition-colors hover:bg-primary-hover"
        >
          Continue to Review
        </Link>
      </div>}
    </div>
  );
}
