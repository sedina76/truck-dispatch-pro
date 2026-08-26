import { getMyDriverApplication } from "../../actions";
import { AgreementForm } from "./agreement-form";

export default async function DriverOnboardingAgreementPage() {
  const application = await getMyDriverApplication();
  if (!application) return null;
  return <AgreementForm application={application} />;
}
