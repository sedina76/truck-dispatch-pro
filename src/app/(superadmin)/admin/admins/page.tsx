import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { RemoveAdminButton } from "@/components/superadmin/remove-admin-button";
import { addPlatformAdmin, removePlatformAdmin } from "./actions";

export default async function SuperAdminAdminsPage() {
  const supabase = await createClient();

  const [{ data: admins }, { data: { user } }] = await Promise.all([
    supabase.from("platform_admins").select("id, full_name, created_at").order("created_at"),
    supabase.auth.getUser(),
  ]);

  return (
    <div className="space-y-6">
      <PageHeader title="Platform Admins" description="Who can access this cross-tenant console." />

      <div className="rounded-xl border border-border bg-card p-5">
        <p className="mb-3 text-sm font-semibold">Grant Access</p>
        <form action={addPlatformAdmin} className="flex flex-wrap items-end gap-3">
          <div className="w-72">
            <label htmlFor="email" className="text-sm font-medium text-foreground">
              Email address
            </label>
            <Input id="email" name="email" type="email" placeholder="person@example.com" required className="mt-1.5" />
          </div>
          <Button type="submit">Add</Button>
        </form>
        <p className="mt-2 text-xs text-muted-foreground">
          The person must already have a Truck Dispatch account (any tenant, any role) -- this only grants them the
          additional platform-console access.
        </p>
      </div>

      <div className="rounded-xl border border-border bg-card p-5">
        <p className="mb-3 text-sm font-semibold">Current Admins</p>
        {!admins || admins.length === 0 ? (
          <p className="text-sm text-muted-foreground">No platform admins found.</p>
        ) : (
          <div className="space-y-2">
            {admins.map((admin) => (
              <div key={admin.id} className="flex items-center justify-between text-sm">
                <div>
                  <p className="font-medium">
                    {admin.full_name}
                    {admin.id === user?.id && <span className="ml-2 text-xs text-muted-foreground">(you)</span>}
                  </p>
                  <p className="text-xs text-muted-foreground">Added {new Date(admin.created_at).toLocaleDateString()}</p>
                </div>
                <RemoveAdminButton action={removePlatformAdmin.bind(null, admin.id)} />
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
