import { getMyDriverApplication } from "../../actions";
import { MedicalCardForm } from "./medical-card-form";

export default async function DriverOnboardingMedicalCardPage() {
  const application = await getMyDriverApplication();
  if (!application) return null;
  return <MedicalCardForm application={application} />;
}
