import "server-only";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getPlatformOverview } from "@/lib/superadmin/platform-metrics";
import { buildReportRows, sortByAttention, monthBuckets, type ReportRow, type ReportUserInput } from "@/lib/superadmin/report-rows";

// Data for Platform Console -> Reports and its CSV export. Callers must
// already be verified platform admins (the (superadmin) layout for the
// page; requirePlatformAdmin() in the export route). Profiles and billing
// records are read through the admin's RLS client (platform-admin select
// policies, 0016/0045); last sign-in times only exist in Supabase Auth, so
// those come from the Auth Admin API (service role, server-only).

async function lastSignIns(): Promise<Map<string, { email: string | null; lastSignInAt: string | null }>> {
  const admin = createServiceRoleClient();
  const out = new Map<string, { email: string | null; lastSignInAt: string | null }>();
  const perPage = 1000;
  for (let page = 1; page <= 50; page += 1) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage });
    if (error || !data) break;
    for (const u of data.users) out.set(u.id, { email: u.email ?? null, lastSignInAt: u.last_sign_in_at ?? null });
    if (data.users.length < perPage) break;
  }
  return out;
}

export type PlatformReport = {
  rows: ReportRow[];
  signupsByMonth: { label: string; count: number }[];
  revenueByMonth: { label: string; count: number; totalCents: number }[];
  revenueAvailable: boolean;
  signInsAvailable: boolean;
};

export async function getPlatformReport(now: Date = new Date()): Promise<PlatformReport> {
  const supabase = await createClient();
  const [overview, profilesRes, billingRes, signIns] = await Promise.all([
    getPlatformOverview(),
    supabase.from("profiles").select("id, organization_id, role, email"),
    supabase.from("billing_records").select("amount_cents, paid_at").eq("status", "paid").order("paid_at", { ascending: false }).limit(5000),
    lastSignIns().catch(() => new Map<string, { email: string | null; lastSignInAt: string | null }>()),
  ]);

  const users: ReportUserInput[] = (profilesRes.data ?? []).map((p) => ({
    id: p.id,
    organizationId: p.organization_id,
    role: p.role,
    email: p.email ?? signIns.get(p.id)?.email ?? null,
    lastSignInAt: signIns.get(p.id)?.lastSignInAt ?? null,
  }));

  const rows = sortByAttention(
    buildReportRows(
      overview.companies.map((c) => ({
        id: c.id,
        name: c.name,
        createdAt: c.createdAt,
        planName: c.planName,
        status: c.status,
        accessKey: c.access.key,
        accessLabel: c.access.label,
        accessDetail: c.access.detail,
        trialEnd: c.trialEnd,
      })),
      users,
      now
    )
  );

  const paid = (billingRes.data ?? []) as { amount_cents: number; paid_at: string | null }[];
  const revenue = monthBuckets(
    paid.map((b) => b.paid_at),
    12,
    now,
    paid.map((b) => b.amount_cents)
  );

  return {
    rows,
    signupsByMonth: monthBuckets(overview.companies.map((c) => c.createdAt), 12, now).map(({ label, count }) => ({ label, count })),
    revenueByMonth: revenue.map(({ label, count, total }) => ({ label, count, totalCents: total })),
    revenueAvailable: !billingRes.error,
    signInsAvailable: signIns.size > 0,
  };
}
