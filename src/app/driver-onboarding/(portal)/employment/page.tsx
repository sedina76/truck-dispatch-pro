import { getMyDriverApplication } from "../../actions";
import { EmploymentForm } from "./employment-form";

export default async function DriverOnboardingEmploymentPage() {
  const application = await getMyDriverApplication();
  if (!application) return null;
  return <EmploymentForm application={application} />;
}
