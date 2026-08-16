import { createClient } from "@/lib/supabase/server";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid } from "@/components/ui/form-field";
import { updateOwnProfile } from "../actions";

export default async function ProfileSettingsPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: profile } = await supabase.from("profiles").select("*").eq("id", user!.id).single();

  return (
    <FormCard
      title="Profile Settings"
      description="Your name, phone, and account details."
      action={updateOwnProfile}
      cancelHref="/dashboard"
      submitLabel="Save Changes"
    >
      <FormGrid>
        <FormField label="Full name" name="full_name" defaultValue={profile?.full_name} required />
        <FormField label="Email" name="email" type="email" defaultValue={profile?.email} required disabled />
        <FormField label="Phone" name="phone" type="tel" defaultValue={profile?.phone} />
        <div className="space-y-1">
          <p className="text-sm font-medium">Role</p>
          <p className="rounded-md border border-[var(--color-border)] bg-[var(--color-bg)] px-3 py-2 text-sm capitalize">
            {profile?.role}
          </p>
        </div>
      </FormGrid>
    </FormCard>
  );
}
