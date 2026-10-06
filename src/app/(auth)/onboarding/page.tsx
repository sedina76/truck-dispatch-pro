import { redirect } from "next/navigation";
import { Building2 } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { AuthShell } from "@/components/auth/auth-shell";
import { AuthCard } from "@/components/auth/auth-card";
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
    <AuthShell centered>
      <AuthCard dark>
        <div className="space-y-5">
          <div className="space-y-3 text-center">
            <div className="mx-auto flex size-14 items-center justify-center rounded-full border border-[#2680ff]/35 bg-[#2680ff]/10 text-[#39a0ff]">
              <Building2 className="size-6" />
            </div>
            <div>
              <h1 className="text-2xl font-bold tracking-tight text-white">Set Up Your Company</h1>
              <p className="mt-1 text-sm text-white/60">
                This becomes your dispatch organization. You&apos;ll be the owner and can invite your team afterward.
              </p>
            </div>
          </div>

          <OnboardingForm />
        </div>
      </AuthCard>
    </AuthShell>
  );
}
