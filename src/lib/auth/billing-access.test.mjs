// Money pages (invoices, payments, statements, settlements) are owner/admin/accountant only,
// matching the database's write rules; dispatchers no longer see screens they cannot save on.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { BILLING_ROLES, canUseBilling, hrefAllowedForRole, isBillingOnlyHref } from "./billing-access.ts";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("billing roles match the database write tier", () => {
  assert.deepEqual([...BILLING_ROLES], ["owner", "admin", "accountant"]);
  for (const r of ["owner", "admin", "accountant"]) assert.equal(canUseBilling(r), true);
  for (const r of ["dispatcher", "driver", "viewer", null, undefined]) assert.equal(canUseBilling(r), false);
});

test("billing-only paths, without catching look-alikes", () => {
  for (const h of ["/invoices", "/invoices/new?load_id=1", "/payments/new", "/statements", "/settlements", "/settlements/abc", "/driver-settlements/new", "/dispatch-fee-invoices", "/dispatch-fee-invoices/new", "/carrier-invoices/abc"]) assert.equal(isBillingOnlyHref(h), true, h);
  for (const h of ["/settings/organization", "/billing", "/billing/ready-to-bill", "/advances", "/accounts-receivable", "/loads", "/invoices-x"]) assert.equal(isBillingOnlyHref(h), false, h);
  assert.equal(hrefAllowedForRole("/invoices", "dispatcher"), false);
  assert.equal(hrefAllowedForRole("/loads/new", "dispatcher"), true);
  assert.equal(hrefAllowedForRole("/invoices", "accountant"), true);
});

test("every money area is guarded with BILLING_ROLES server-side", () => {
  for (const p of ["../../app/(app)/invoices/layout.tsx", "../../app/(app)/payments/layout.tsx", "../../app/(app)/statements/layout.tsx",
                   "../../app/(app)/settlements/layout.tsx", "../../app/(app)/driver-settlements/layout.tsx", "../../app/(app)/dispatch-fee-invoices/layout.tsx", "../../app/(app)/carrier-invoices/layout.tsx", "../../app/payments/[id]/receipt/page.tsx"]) {
    assert.match(read(p), /requireRole\(BILLING_ROLES\)/, p);
  }
  for (const p of ["../../app/invoices/[id]/pdf/route.ts", "../../app/(app)/statements/[id]/pdf/route.ts", "../../app/(app)/invoices/export/route.ts", "../../app/(app)/payments/export/route.ts", "../../app/(app)/dispatch-fee-invoices/[id]/pdf/route.ts", "../../app/(app)/carrier-invoices/[id]/pdf/route.ts", "../../app/(app)/carrier-invoices/[id]/package/route.ts"]) {
    assert.match(read(p), /requireRoleForApi\(BILLING_ROLES\)/, p);
  }
});

test("menus hide money destinations by role", () => {
  assert.match(read("../../components/desktop/billing-subnav.tsx"), /BILLING_TABS\.filter\(\(tab\) => hrefAllowedForRole\(tab\.href, role\)\)/);
  assert.match(read("../../components/desktop/menu-bar.tsx"), /hrefAllowedForRole\(item\.href, role\)/);
  const palette = read("../../components/nav/command-palette.tsx");
  assert.match(palette, /QUICK_CREATE\.filter\(\(item\) => hrefAllowedForRole\(item\.href, role\)\)/);
  assert.match(palette, /NAV_ITEMS\.filter\(\(item\) => hrefAllowedForRole\(item\.href, role\)\)/);
  assert.match(read("../../app/(app)/layout.tsx"), /<RoleProvider role=\{profile\.role\}>/);
  const nav = read("../../components/nav/nav-config.ts");
  // Settlements are tabs inside "Pay & Expenses"; the tab row hides them by role.
  const ws = read("../../components/nav/workspaces.ts");
  assert.match(ws, /label: "Carrier Settlements", href: "\/settlements"/);
  assert.match(ws, /label: "Driver Settlements", href: "\/driver-settlements"/);
  assert.match(read("../../components/desktop/workspace-tabs-auto.tsx"), /ws\.tabs\.filter\(\(t\) => hrefAllowedForRole\(t\.href, role\)\)/);
  assert.match(nav, /href: "\/dispatch-fee-invoices", icon: FileText, roles: \["owner", "admin", "accountant"\]/);
});
