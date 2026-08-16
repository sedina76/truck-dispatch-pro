import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { OnboardingForm } from "./onboarding-form";

export default async function OnboardingPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: profile } = await supabase
    .from("profiles")
    .select("organization_id")
    .eq("id", user.id)
    .single();

  if (profile?.organization_id) redirect("/dashboard");

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-xl font-semibold">Set up your company</h1>
        <p className="mt-1 text-sm text-[var(--color-text-muted)]">
          This becomes your dispatch organization. You&apos;ll be the owner and can invite your
          team afterward.
        </p>
      </div>

      <OnboardingForm />
    </div>
  );
}
