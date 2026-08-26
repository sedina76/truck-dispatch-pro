import { getMyDriverApplication } from "../../actions";
import { LicenseForm } from "./license-form";

export default async function DriverOnboardingLicensePage() {
  const application = await getMyDriverApplication();
  if (!application) return null;
  return <LicenseForm application={application} />;
}
