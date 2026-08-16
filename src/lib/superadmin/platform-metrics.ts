import "server-only";
import { createClient } from "@/lib/supabase/server";

// ONE canonical module for every number the Platform Console Overview
// shows. Every query here runs through the caller's own RLS-scoped
// client (never service-role) -- cross-tenant reads work only because of
// the 4 existing platform-admin-select policies (0016_platform_admin.sql)
// plus the 2 additive ones from 0045_platform_console_redesign.sql. A
// non-platform-admin session gets empty results from every one of these
// (RLS-enforced), never an error that could leak existence.
//
// METRIC                 SOURCE                                    CALC / FILTER                                          HISTORICAL?
// ---------------------  ----------------------------------------  ------------------------------------------------------  -----------
// Total Companies         organizations                             count(*)                                               current
// Active Subscriptions    organization_subscriptions                count(status = 'active')                               current
// MRR                     organization_subscriptions + plans        sum(monthly_price_cents) where status='active'          current
// ARR                     (derived)                                 MRR * 12 -- no separate revenue system                  current
// Past Due                organization_subscriptions                count(status = 'past_due')                             current
// At Risk                 organization_subscriptions                count(status in ('past_due','incomplete'))             current
// Company Growth          organizations.created_at                  count grouped by month                                 REAL historical
// MRR trend               --                                        NOT reconstructable -- no MRR snapshot/ledger table    UNAVAILABLE (honest)
// Subscription breakdown  organization_subscriptions + plans        grouped by (status='trialing' ? 'Trialing' : plan.name) current
// Companies table         organizations + organization_subscriptions + subscription_plans  1:1 join, no per-row query      current
// Active Users            profiles                                  count(is_active = true), platform-wide                 current
// Live Dispatches         get_platform_operational_snapshot() RPC   count of in-progress dispatch statuses                 current (needs 0045)
// Open Invoices           get_platform_operational_snapshot() RPC   count(status not in paid/void)                         current (needs 0045)
// Recent Platform Activity organizations/subscriptions/billing_records/activity_logs timestamps  merged, sorted desc        REAL (not fabricated)

export type SubscriptionStatus = "trialing" | "active" | "past_due" | "canceled" | "incomplete" | "paused";

export type CompanyRow = {
  id: string;
  name: string;
  slug: string;
  createdAt: string;
  planName: string | null;
  planId: string | null;
  status: SubscriptionStatus | null;
  mrrCents: number;
};

export type BreakdownSlice = { label: string; count: number; mrrCents: number; percent: number };

export type ActivityEntry = {
  id: string;
  kind: "company_created" | "subscription_status" | "payment_received" | "admin_action";
  title: string;
  detail: string;
  occurredAt: string;
};

export type PlatformOverview = {
  totals: {
    companyCount: number;
    activeCount: number;
    trialingCount: number;
    pastDueCount: number;
    atRiskCount: number;
    mrrCents: number;
    arrCents: number;
  };
  companyGrowth: { month: string; count: number }[];
  breakdown: BreakdownSlice[];
  companies: CompanyRow[];
  activity: ActivityEntry[];
  operational: { activeUsers: number | null; liveDispatches: number | null; openInvoices: number | null; available: boolean };
  usersByOrg: Map<string, number>;
};

function monthLabel(iso: string): string {
  const d = new Date(iso);
  return d.toLocaleString("en-US", { month: "short", year: "2-digit" });
}

export async function getPlatformOverview(): Promise<PlatformOverview> {
  const supabase = await createClient();

  const [orgsRes, subsRes, recentSubsRes, recentBillingRes, snapshotRes, activityRes, profilesRes] = await Promise.all([
    supabase.from("organizations").select("id, name, slug, created_at").order("created_at", { ascending: false }),
    supabase
      .from("organization_subscriptions")
      .select("organization_id, plan_id, status, updated_at, subscription_plans(name, monthly_price_cents)"),
    // Small slice for the activity feed -- most-recently-changed subscriptions only.
    supabase.from("organization_subscriptions").select("organization_id, status, updated_at").order("updated_at", { ascending: false }).limit(20),
    // Real paid billing history -- for the activity feed's "payment received" entries. Not a second MRR calculation.
    supabase.from("billing_records").select("id, organization_id, amount_cents, paid_at").eq("status", "paid").order("paid_at", { ascending: false }).limit(20),
    supabase.rpc("get_platform_operational_snapshot").maybeSingle(),
    // Requires 0045's activity_logs_platform_admin_select policy -- if that
    // migration hasn't run yet, RLS simply returns nothing (not an error),
    // which the feed below treats as "no admin-action entries yet," never a crash.
    supabase.from("activity_logs").select("id, entity_type, entity_id, action, created_at, organization_id").order("created_at", { ascending: false }).limit(20),
    // Per-company user counts for the table's Users column, AND the
    // platform-wide Active Users total -- one query (profiles_platform_
    // admin_select, 0016, already exists -- no migration needed for this
    // one), grouped/counted client-side. Never one query per company.
    supabase.from("profiles").select("id, organization_id, is_active"),
  ]);

  const orgs = orgsRes.data;
  const subs = subsRes.data;
  const recentSubs = recentSubsRes.data;
  const recentBilling = recentBillingRes.data;
  const activityRows = activityRes.data;

  const usersByOrg = new Map<string, number>();
  let totalActiveUsers = 0;
  for (const p of profilesRes.data ?? []) {
    if (p.is_active) totalActiveUsers += 1;
    if (!p.organization_id) continue;
    usersByOrg.set(p.organization_id, (usersByOrg.get(p.organization_id) ?? 0) + 1);
  }

  type SubRow = { organization_id: string; plan_id: string | null; status: SubscriptionStatus; updated_at: string; subscription_plans: { name: string; monthly_price_cents: number } | null };
  const subscriptions = (subs ?? []) as unknown as SubRow[];
  const subByOrg = new Map(subscriptions.map((s) => [s.organization_id, s]));
  const orgById = new Map((orgs ?? []).map((o) => [o.id, o]));

  const activeSubs = subscriptions.filter((s) => s.status === "active");
  const mrrCents = activeSubs.reduce((sum, s) => sum + (s.subscription_plans?.monthly_price_cents ?? 0), 0);

  const totals = {
    companyCount: orgs?.length ?? 0,
    activeCount: activeSubs.length,
    trialingCount: subscriptions.filter((s) => s.status === "trialing").length,
    pastDueCount: subscriptions.filter((s) => s.status === "past_due").length,
    atRiskCount: subscriptions.filter((s) => s.status === "past_due" || s.status === "incomplete").length,
    mrrCents,
    arrCents: mrrCents * 12, // canonical: ARR = MRR x 12, no separate revenue system
  };

  // Company Growth -- real historical signups by month (organizations.created_at).
  const growthMap = new Map<string, { sortKey: string; count: number }>();
  for (const org of orgs ?? []) {
    const d = new Date(org.created_at);
    const sortKey = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
    const label = monthLabel(org.created_at);
    const existing = growthMap.get(label);
    if (existing) existing.count += 1;
    else growthMap.set(label, { sortKey, count: 1 });
  }
  const companyGrowth = Array.from(growthMap.entries())
    .map(([month, v]) => ({ month, count: v.count, sortKey: v.sortKey }))
    .sort((a, b) => a.sortKey.localeCompare(b.sortKey))
    .map(({ month, count }) => ({ month, count }));

  // Subscription breakdown -- grouped by real bucket: Trialing (status) or
  // the real plan name (Starter/Professional/Enterprise -- this schema
  // has no "Standard"/"Basic" tier; using the real names rather than
  // inventing ones that don't exist).
  const breakdownMap = new Map<string, { count: number; mrrCents: number }>();
  for (const s of subscriptions) {
    const label = s.status === "trialing" ? "Trialing" : s.subscription_plans?.name ?? "No plan";
    const entry = breakdownMap.get(label) ?? { count: 0, mrrCents: 0 };
    entry.count += 1;
    if (s.status === "active") entry.mrrCents += s.subscription_plans?.monthly_price_cents ?? 0;
    breakdownMap.set(label, entry);
  }
  const breakdownTotal = subscriptions.length || 1;
  const breakdown: BreakdownSlice[] = Array.from(breakdownMap.entries()).map(([label, v]) => ({
    label,
    count: v.count,
    mrrCents: v.mrrCents,
    percent: Math.round((v.count / breakdownTotal) * 1000) / 10,
  }));

  // Companies table -- single join already fetched above, no per-row query.
  const companies: CompanyRow[] = (orgs ?? []).map((org) => {
    const sub = subByOrg.get(org.id);
    return {
      id: org.id,
      name: org.name,
      slug: org.slug,
      createdAt: org.created_at,
      planName: sub?.subscription_plans?.name ?? null,
      planId: sub?.plan_id ?? null,
      status: sub?.status ?? null,
      mrrCents: sub?.status === "active" ? sub.subscription_plans?.monthly_price_cents ?? 0 : 0,
    };
  });

  // Recent Platform Activity -- merged from real state-change timestamps
  // across 3 tables plus (if 0045 has run) real admin-action log entries.
  // Every entry here corresponds to a real row; nothing is invented.
  const activity: ActivityEntry[] = [];
  for (const org of (orgs ?? []).slice(0, 8)) {
    activity.push({ id: `org-${org.id}`, kind: "company_created", title: "Company created", detail: org.name, occurredAt: org.created_at });
  }
  for (const s of (recentSubs ?? []) as unknown as { organization_id: string; status: SubscriptionStatus; updated_at: string }[]) {
    const org = orgById.get(s.organization_id);
    if (!org) continue;
    activity.push({
      id: `sub-${s.organization_id}-${s.updated_at}`,
      kind: "subscription_status",
      title: `Subscription ${s.status.replace(/_/g, " ")}`,
      detail: org.name,
      occurredAt: s.updated_at,
    });
  }
  for (const b of (recentBilling ?? []) as unknown as { id: string; organization_id: string; amount_cents: number; paid_at: string }[]) {
    const org = orgById.get(b.organization_id);
    if (!org || !b.paid_at) continue;
    activity.push({
      id: `bill-${b.id}`,
      kind: "payment_received",
      title: `Payment received -- $${(b.amount_cents / 100).toLocaleString(undefined, { minimumFractionDigits: 2 })}`,
      detail: org.name,
      occurredAt: b.paid_at,
    });
  }
  for (const a of activityRows ?? []) {
    const org = orgById.get(a.organization_id);
    if (!org) continue;
    activity.push({
      id: `log-${a.id}`,
      kind: "admin_action",
      title: `Platform admin: ${a.action.replace(/_/g, " ")}`,
      detail: org.name,
      occurredAt: a.created_at,
    });
  }
  activity.sort((a, b) => new Date(b.occurredAt).getTime() - new Date(a.occurredAt).getTime());

  // Operational snapshot -- Active Users comes directly from the profiles
  // query above (existing policy, no migration needed). Live Dispatches/
  // Open Invoices require 0045's get_platform_operational_snapshot() RPC;
  // if it doesn't exist yet (migration not applied), that call errors and
  // those two surface "unavailable" honestly rather than a fake zero.
  const snapshotError = snapshotRes.error;
  const snapshotData = snapshotRes.data as { active_users: number; live_dispatches: number; open_invoices: number } | null;
  const operational = snapshotError || !snapshotData
    ? { activeUsers: totalActiveUsers, liveDispatches: null, openInvoices: null, available: false }
    : { activeUsers: totalActiveUsers, liveDispatches: snapshotData.live_dispatches, openInvoices: snapshotData.open_invoices, available: true };

  return {
    totals,
    companyGrowth,
    breakdown,
    companies,
    activity: activity.slice(0, 12),
    operational,
    usersByOrg,
  };
}

function money(cents: number): string {
  return `$${(cents / 100).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export { money as formatCents };
