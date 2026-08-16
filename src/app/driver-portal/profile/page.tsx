import { redirect } from "next/navigation";
import { UserRound } from "lucide-react";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { ProfileForm } from "@/components/driver-portal/profile-form";

// My Profile (spec section 25) -- explicit safe allowlist, both for what's
// SELECTed here and for what updateMyDriverProfile is willing to WRITE.
// No SSN, pay rate, compliance, employment status, settlement data,
// organization, or carrier assignment anywhere in this page.
export default async function DriverPortalProfilePage() {
  const identity = await getDriverPortalSession();
  if (!identity) redirect("/driver-portal/login");

  const supabase = createServiceRoleClient();
  const { data: driver } = await supabase
    .from("drivers")
    .select("phone, email, emergency_contact_name, emergency_contact_phone")
    .eq("id", identity.driverId)
    .single();

  return (
    <div className="flex flex-1 flex-col gap-4">
      <h1 className="flex items-center gap-2 text-lg font-semibold tracking-tight">
        <UserRound className="size-4.5 text-primary" /> My Profile
      </h1>
      <div className="rounded-2xl border border-border bg-card p-4">
        <ProfileForm
          phone={driver?.phone ?? null}
          email={driver?.email ?? null}
          emergencyContactName={driver?.emergency_contact_name ?? null}
          emergencyContactPhone={driver?.emergency_contact_phone ?? null}
        />
      </div>
    </div>
  );
}
