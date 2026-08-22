import { getMyApplication } from "../../actions";
import { CompanyForm } from "./company-form";

export default async function OnboardingCompanyPage() {
  const application = await getMyApplication();
  return (
    <div className="rounded-md border border-desktop-border bg-card p-4 sm:p-5">
      <h2 className="text-[15px] font-semibold text-desktop-text">Company Information</h2>
      <p className="mt-0.5 text-[13px] text-muted-foreground">Tell us about your company. You can update this later if needed.</p>
      <CompanyForm application={application} />
    </div>
  );
}
