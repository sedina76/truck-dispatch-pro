import { getMyDriverApplication } from "../../actions";
import { PersonalInfoForm } from "./personal-form";

export default async function DriverOnboardingPersonalPage() {
  const application = await getMyDriverApplication();
  if (!application) return null;
  return <PersonalInfoForm application={application} />;
}
