import { getMyDriverApplication, getMyDriverW9 } from "../../actions";
import { workerTypeRequiresW9, type DriverWorkerType } from "@/lib/driver-w9/types";
import { ReviewSubmit } from "./review-submit";

export default async function DriverOnboardingReviewPage() {
  const application = await getMyDriverApplication();
  if (!application) return null;
  const requiresW9 = workerTypeRequiresW9(application.worker_type as DriverWorkerType | null);
  const w9 = requiresW9 ? await getMyDriverW9() : null;
  return <ReviewSubmit application={application} requiresW9={requiresW9} w9Status={w9?.status ?? null} />;
}
