import { getMyApplication } from "../../actions";
import { EquipmentForm } from "./equipment-form";

export default async function OnboardingEquipmentPage() {
  const application = await getMyApplication();
  return (
    <div className="rounded-md border border-desktop-border bg-card p-4 sm:p-5">
      <h2 className="text-[15px] font-semibold text-desktop-text">Equipment</h2>
      <p className="mt-0.5 text-[13px] text-muted-foreground">Tell us about your trucks, trailers, and the freight you prefer to haul.</p>
      <EquipmentForm equipmentData={application.equipmentData} />
    </div>
  );
}
