import Link from "next/link";
import { CheckCircle2, XCircle, Clock } from "lucide-react";
import { getMyApplication, getDocumentChecklist, getAgreementsForSigning, getMyRequiredAgreementReadiness } from "../../actions";
import { SubmitButton } from "./submit-button";

export default async function OnboardingReviewPage() {
  const [application, checklist, signings, agreementReadiness] = await Promise.all([getMyApplication(), getDocumentChecklist(), getAgreementsForSigning(), getMyRequiredAgreementReadiness()]);

  const alreadySubmitted = !["draft", "needs_correction"].includes(application.status);
  const missingRequiredDocs = checklist.filter((c) => c.requirement === "required" && c.status !== "accepted" && c.status !== "uploaded");
  const frozenRequiredSigningIds = new Set(agreementReadiness.requirements.map((requirement) => requirement.signingId).filter(Boolean));
  // Every assigned agreement is shown on its own row below (spec section
  // 4: the portal must never collapse multiple distinct agreements into
  // one summary line). This can't detect a required agreement staff never
  // assigned at all -- submitApplication() itself is the authoritative
  // gate for that case and will surface its own error on submit.

  return (
    <div className="space-y-4">
      <div className="rounded-md border border-desktop-border bg-card p-4 sm:p-5">
        <h2 className="text-[15px] font-semibold text-desktop-text">Review &amp; Submit</h2>

        <div className="mt-3 space-y-2">
          <SummaryRow label="Company Information" ok={Boolean(application.legalName && application.contactName && application.email && application.phone)} href="/carrier-onboarding/company" />
          <SummaryRow label="Equipment" ok={Boolean(application.equipmentData)} href="/carrier-onboarding/equipment" optional />
          <SummaryRow label="Required Documents" ok={missingRequiredDocs.length === 0} href="/carrier-onboarding/documents" detail={missingRequiredDocs.length > 0 ? `${missingRequiredDocs.length} still needed` : undefined} />
          <SummaryRow label="Agreements" ok={agreementReadiness.ready} href="/carrier-onboarding/agreement" detail={!agreementReadiness.initialized ? "Being prepared" : agreementReadiness.requirements.length === 0 ? "No agreements required" : `${agreementReadiness.completedCount} of ${agreementReadiness.requirements.length} completed`} />
          {signings.filter((s) => !frozenRequiredSigningIds.has(s.signingId)).map((s) => (
            <SummaryRow
              key={s.signingId}
              label={s.templateName}
              ok={s.status === "completed"}
              href="/carrier-onboarding/agreement"
              detail={s.status !== "completed" ? "Not yet signed" : undefined}
              optional={!s.isRequiredForOnboarding}
            />
          ))}
        </div>

        {application.status === "submitted" && (
          <div className="mt-4 flex items-center gap-2 rounded-sm border border-desktop-border bg-desktop-bg px-3 py-2.5 text-[13px] text-desktop-text">
            <Clock className="size-4 shrink-0 text-muted-foreground" />
            Submitted -- our office is reviewing your application.
          </div>
        )}

        {!alreadySubmitted && (
          <div className="mt-4 border-t border-desktop-border pt-4">
            <SubmitButton disabled={!agreementReadiness.ready} />
          </div>
        )}
      </div>
    </div>
  );
}

function SummaryRow({ label, ok, href, detail, optional }: { label: string; ok: boolean; href: string; detail?: string; optional?: boolean }) {
  return (
    <Link href={href} className="flex items-center justify-between rounded-sm border border-desktop-border px-3 py-2 hover:bg-desktop-muted">
      <div className="flex items-center gap-2">
        {ok ? <CheckCircle2 className="size-4 shrink-0 text-desktop-success" /> : <XCircle className={optional ? "size-4 shrink-0 text-muted-foreground" : "size-4 shrink-0 text-desktop-danger"} />}
        <span className="text-[13px] font-medium text-desktop-text">{label}</span>
      </div>
      {detail && <span className="text-[11.5px] text-muted-foreground">{detail}</span>}
    </Link>
  );
}
