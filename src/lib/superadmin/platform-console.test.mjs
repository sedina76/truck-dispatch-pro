// Platform Console: Reports, Settings, real access status, suspension that
// works for every company, and the 0171 guard on billing/suspension flags.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolveBillingAccess } from "../billing/access-policy.ts";
import { describeAccess, toBillingFacts } from "./company-access.ts";
const companyAccess = (f) => describeAccess(resolveBillingAccess(toBillingFacts(f)), f);
import { buildReportRows, sortByAttention, monthBuckets, reportCsv } from "./report-rows.ts";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const now = new Date("2026-10-06T22:00:00Z");
const base = { billingRequired: true, subscriptionExists: true, grandfatheredAt: null, status: "active", pastDueSince: null, now };

test("suspension blocks every company: free access, legacy and paying alike", () => {
  assert.deepEqual(resolveBillingAccess({ ...base, suspended: true }), { access: "billing_only", reason: "suspended" });
  assert.equal(resolveBillingAccess({ ...base, billingRequired: false, suspended: true }).access, "billing_only");
  assert.equal(resolveBillingAccess({ ...base, grandfatheredAt: "2026-01-01T00:00:00Z", suspended: true }).access, "billing_only");
  // not suspended: unchanged behaviour
  assert.equal(resolveBillingAccess({ ...base, billingRequired: false, suspended: false }).access, "full");
  assert.equal(resolveBillingAccess({ ...base }).access, "full");
});

const facts = (o) => ({ isActive: true, billingRequired: true, status: null, grandfatheredAt: null, pastDueSince: null, trialEnd: null, now, ...o });

test("console access labels match what the app really does", () => {
  assert.equal(companyAccess(facts({ billingRequired: false })).key, "free");
  const locked = companyAccess(facts({ billingRequired: true, status: null }));
  assert.equal(locked.key, "locked");
  assert.equal(locked.canUseApp, false);
  assert.match(locked.detail, /no subscription was ever started/);
  assert.equal(companyAccess(facts({ status: "active" })).key, "paying");
  const trial = companyAccess(facts({ status: "trialing", trialEnd: "2026-10-15T00:00:00Z" }));
  assert.equal(trial.key, "trial");
  assert.equal(trial.label, "Trial to Oct 15, 2026");
  assert.equal(companyAccess(facts({ status: "canceled" })).key, "locked");
  assert.equal(companyAccess(facts({ status: "paused" })).key, "suspended"); // old-style suspension
  assert.equal(companyAccess(facts({ isActive: false, billingRequired: false })).key, "suspended");
  assert.equal(companyAccess(facts({ status: "past_due", pastDueSince: "2026-10-04T00:00:00Z" })).key, "grace");
  assert.equal(companyAccess(facts({ status: "canceled", grandfatheredAt: "2026-01-01T00:00:00Z" })).key, "legacy");
});

const company = (o) => ({ id: "c1", name: "Acme", createdAt: "2026-09-01T00:00:00Z", planName: null, status: null, accessKey: "free", accessLabel: "Free access", accessDetail: "", trialEnd: null, ...o });

test("report rows: owner, users, last sign-in and what needs attention", () => {
  const users = [
    { id: "u1", organizationId: "c1", role: "dispatcher", email: "d@acme.com", lastSignInAt: "2026-10-05T10:00:00Z" },
    { id: "u2", organizationId: "c1", role: "owner", email: "owner@acme.com", lastSignInAt: "2026-08-01T10:00:00Z" },
    { id: "u3", organizationId: "c2", role: "owner", email: "k@kali.com", lastSignInAt: null },
  ];
  const rows = buildReportRows(
    [
      company({}),
      company({ id: "c2", name: "Kali", accessKey: "locked", accessLabel: "Locked out" }),
      company({ id: "c3", name: "Trial Co", accessKey: "trial", trialEnd: "2026-10-12T00:00:00Z" }),
      company({ id: "c4", name: "Idle", accessKey: "paying", status: "active" }),
    ],
    [...users, { id: "u4", organizationId: "c4", role: "owner", email: "i@idle.com", lastSignInAt: "2026-07-01T00:00:00Z" }],
    now
  );
  const by = Object.fromEntries(rows.map((r) => [r.id, r]));
  assert.equal(by.c1.ownerEmail, "owner@acme.com");
  assert.equal(by.c1.userCount, 2);
  assert.equal(by.c1.lastSignInAt, "2026-10-05T10:00:00Z");
  assert.deepEqual(by.c1.attention, []);
  assert.deepEqual(by.c2.attention, ["locked", "never_signed_in"]);
  assert.deepEqual(by.c3.attention, ["trial_ending", "never_signed_in"]);
  assert.deepEqual(by.c4.attention, ["inactive"]);
  assert.equal(sortByAttention(rows)[0].id, "c2", "locked-out companies come first");
});

test("month buckets are zero-filled and sum amounts", () => {
  const b = monthBuckets(["2026-10-01T00:00:00Z", "2026-10-20T00:00:00Z", "2026-08-03T00:00:00Z", "2025-01-01T00:00:00Z", null], 3, now, [100, 250, 5, 999, 1]);
  assert.deepEqual(b.map((x) => [x.key, x.count, x.total]), [["2026-08", 1, 5], ["2026-09", 0, 0], ["2026-10", 2, 350]]);
});

test("CSV export quotes commas and neutralises spreadsheet formulas", () => {
  const csv = reportCsv([{ ...company({ name: '=HYPERLINK("x"), Inc' }), ownerEmail: null, userCount: 0, lastSignInAt: null, attention: ["never_signed_in"] }]);
  const line = csv.split("\r\n")[1];
  assert.ok(line.startsWith(`"'=HYPERLINK(""x""), Inc"`), line);
  assert.match(line, /never/);
});

test("Stripe mode is read from the key prefix only", async () => {
  // platform-config imports "server-only" + the email provider, so check the pure logic by source
  const cfg = src("./platform-config.ts");
  assert.match(cfg, /\/\^\(sk\|rk\)_live_\//);
  assert.match(cfg, /\/\^\(sk\|rk\)_test_\//);
  assert.doesNotMatch(cfg, /value: env\.STRIPE_SECRET_KEY/, "never shows the secret itself");
});

test("Reports and Settings are real pages in the console menu", () => {
  const nav = src("../../components/superadmin/superadmin-sidebar.tsx");
  assert.match(nav, /\{ label: "Reports", href: "\/admin\/reports", icon: BarChart3 \}/);
  assert.match(nav, /\{ label: "Settings", href: "\/admin\/settings", icon: Settings \}/);
  assert.doesNotMatch(nav, /COMING_SOON|>Soon</);
  const exportRoute = src("../../app/(superadmin)/admin/reports/export/route.ts");
  assert.match(exportRoute, /await requirePlatformAdmin\(\);/, "the CSV route checks platform-admin access itself");
});

test("Settings: own account only, current password checked, other devices can be signed out", () => {
  const a = src("../../app/(superadmin)/admin/settings/actions.ts");
  assert.match(a, /requirePlatformAdmin\(\)/);
  assert.match(a, /passwordIsCorrect\(user\.email \?\? "", current\)/);
  assert.match(a, /passwordIsCorrect\(user\.email \?\? "", password\)/);
  assert.match(a, /persistSession: false/, "password check never touches the admin's own session");
  assert.match(a, /signOut\(\{ scope: "local" \}\)/);
  assert.match(a, /signOut\(\{ scope: "others" \}\)/);
  assert.match(a, /\.eq\("id", user\.id\)/, "name change is scoped to the caller");
  assert.match(a, /next=\/admin\/settings/);
});

test("Suspend and Free access are platform-only switches on the company row", () => {
  const a = src("../../app/(superadmin)/admin/companies/access-actions.ts");
  assert.match(a, /update\(\{ is_active: !suspend \}\)/);
  assert.match(a, /update\(\{ billing_required: !free \}\)/);
  assert.equal((a.match(/await requirePlatformAdmin\(\)/g) ?? []).length, 2);
  const sql = src("../../../supabase/migrations/0171_platform_controlled_org_flags.sql");
  assert.match(sql, /new\.billing_required is distinct from old\.billing_required/);
  assert.match(sql, /new\.is_active is distinct from old\.is_active/);
  assert.match(sql, /and auth\.uid\(\) is not null\s+and not public\.is_platform_admin\(\)/);
  assert.match(sql, /before update on public\.organizations/);
});
