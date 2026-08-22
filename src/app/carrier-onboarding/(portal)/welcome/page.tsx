import Link from "next/link";
import { FileText, Truck, ClipboardList, PenLine, CheckCircle2 } from "lucide-react";
import { getMyApplication } from "../../actions";

export default async function OnboardingWelcomePage() {
  const application = await getMyApplication();
  const alreadySubmitted = !["draft", "needs_correction"].includes(application.status);

  return (
    <div className="space-y-4">
      <div className="rounded-md border border-desktop-border bg-card p-5">
        <h2 className="text-base font-semibold text-desktop-text">
          {application.legalName ? `Welcome, ${application.legalName}` : "Welcome"}
        </h2>
        <p className="mt-1.5 text-sm text-muted-foreground">
          We&apos;re glad to be working with you. This short packet collects your company information, equipment
          details, required documents, and your dispatch agreement -- everything our office needs to get you
          activated. It takes most carriers about 10 minutes.
        </p>

        {application.status === "needs_correction" && application.reviewNotes && (
          <div className="mt-3 rounded-sm border border-warning/30 bg-warning/10 p-2.5 text-[13px] text-desktop-text">
            <p className="font-medium">Our office requested a correction:</p>
            <p className="mt-0.5 text-muted-foreground">{application.reviewNotes}</p>
          </div>
        )}

        <div className="mt-4 grid grid-cols-1 gap-2.5 sm:grid-cols-2">
          {[
            { icon: Truck, label: "Company Information" },
            { icon: ClipboardList, label: "Equipment" },
            { icon: FileText, label: "Required Documents" },
            { icon: PenLine, label: "Dispatch Agreement" },
          ].map((item) => (
            <div key={item.label} className="flex items-center gap-2 rounded-sm border border-desktop-border bg-desktop-bg px-3 py-2">
              <item.icon className="size-4 shrink-0 text-primary" />
              <span className="text-[13px] font-medium text-desktop-text">{item.label}</span>
            </div>
          ))}
        </div>

        <p className="mt-4 text-[12px] text-muted-foreground">
          You can save your progress and come back at any time using the same link.
        </p>

        {alreadySubmitted ? (
          <div className="mt-4 flex items-center gap-2 rounded-sm border border-success/30 bg-success/10 px-3 py-2.5 text-[13px] text-desktop-text">
            <CheckCircle2 className="size-4 shrink-0 text-success" />
            You&apos;ve already submitted this application. You can still review what you sent.
          </div>
        ) : null}

        <Link
          href={alreadySubmitted ? "/carrier-onboarding/review" : "/carrier-onboarding/company"}
          className="mt-4 inline-flex h-10 w-full items-center justify-center rounded-sm bg-primary text-[14px] font-medium text-primary-foreground shadow-elevation-1 transition-colors hover:bg-primary-hover sm:w-auto sm:px-5"
        >
          {alreadySubmitted ? "Review My Application" : "Get Started"}
        </Link>
      </div>
    </div>
  );
}
