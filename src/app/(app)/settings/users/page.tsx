import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { KpiRow, KpiCard } from "@/components/ui/kpi-card";
import { StatusBadge } from "@/components/ui/status-badge";
import { Button } from "@/components/ui/button";
import { updateUserRole, toggleUserActive } from "../actions";

const ROLES = ["owner", "admin", "dispatcher", "accountant", "driver", "viewer"];

export default async function UsersSettingsPage() {
  const supabase = await createClient();
  const { data: profiles } = await supabase
    .from("profiles")
    .select("id, full_name, email, phone, role, is_active")
    .order("full_name");

  const activeCount = (profiles ?? []).filter((p) => p.is_active).length;

  return (
    <div className="space-y-6">
      <PageHeader
        title="Users & Roles"
        description="Manage your team's roles and access. New teammates join via sign-up, then appear here for you to assign a role."
      />

      <KpiRow>
        <KpiCard label="Total Users" value={profiles?.length ?? 0} />
        <KpiCard label="Active" value={activeCount} />
        <KpiCard label="Deactivated" value={(profiles?.length ?? 0) - activeCount} />
      </KpiRow>

      <div className="overflow-x-auto rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)]">
        <table className="w-full min-w-max text-sm">
          <thead>
            <tr className="border-b border-[var(--color-border)] text-left text-xs font-medium uppercase tracking-wide text-[var(--color-text-muted)]">
              <th className="px-4 py-3">Name</th>
              <th className="px-4 py-3">Email</th>
              <th className="px-4 py-3">Phone</th>
              <th className="px-4 py-3">Role</th>
              <th className="px-4 py-3">Status</th>
              <th className="px-4 py-3 text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            {(profiles ?? []).map((p) => (
              <tr key={p.id} className="border-b border-[var(--color-border)] last:border-0">
                <td className="px-4 py-3 font-medium">{p.full_name}</td>
                <td className="px-4 py-3">{p.email}</td>
                <td className="px-4 py-3">{p.phone ?? "--"}</td>
                <td className="px-4 py-3">
                  <form action={updateUserRole.bind(null, p.id)} className="flex items-center gap-2">
                    <select
                      name="role"
                      defaultValue={p.role}
                      className="rounded-md border border-[var(--color-border)] bg-[var(--color-surface)] px-2 py-1 text-xs outline-none focus:ring-2 focus:ring-[var(--color-brand)]"
                    >
                      {ROLES.map((r) => (
                        <option key={r} value={r}>
                          {r}
                        </option>
                      ))}
                    </select>
                    <Button type="submit" size="sm" variant="ghost">
                      Save
                    </Button>
                  </form>
                </td>
                <td className="px-4 py-3">
                  <StatusBadge status={p.is_active ? "active" : "inactive"} />
                </td>
                <td className="px-4 py-3 text-right">
                  <form action={toggleUserActive.bind(null, p.id, p.is_active)}>
                    <Button type="submit" size="sm" variant={p.is_active ? "danger" : "ghost"}>
                      {p.is_active ? "Deactivate" : "Activate"}
                    </Button>
                  </form>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
