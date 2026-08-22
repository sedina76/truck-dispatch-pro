import { CheckCircle2 } from "lucide-react";
import { getMyApplication } from "../../actions";

export default async function OnboardingCompletePage() {
  const application = await getMyApplication();
  const submitted = !["draft", "needs_correction"].includes(application.status);

  return (
    <div className="rounded-md border border-desktop-border bg-card p-6 text-center">
      <CheckCircle2 className="mx-auto size-10 text-desktop-success" />
      <h2 className="mt-3 text-base font-semibold text-desktop-text">
        {submitted ? "Application Submitted" : "Not Quite Done Yet"}
      </h2>
      <p className="mt-2 text-[13px] text-muted-foreground">
        {submitted
          ? "Thank you. Our office has received your carrier onboarding packet and will be in touch soon."
          : "It looks like your application hasn't been submitted yet -- please go back and finish the Review & Submit step."}
      </p>
    </div>
  );
}
