// Top menus and toolbar: every link is a real page, each role only sees
// what it can open, and the order follows the work (book -> dispatch ->
// track -> bill -> get paid -> settle).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { hrefAllowedForRole } from "../../lib/auth/billing-access.ts";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const menuBar = src("./menu-bar.tsx");
const toolbar = src("./toolbar.tsx");

test("every menu and toolbar link opens a real page", () => {
  const hrefs = [...menuBar.matchAll(/href: "([^"]+)"/g), ...toolbar.matchAll(/href[=:] ?"([^"]+)"/g)].map((m) => m[1].split("?")[0]);
  assert.ok(hrefs.length > 50);
  for (const h of new Set(hrefs)) assert.ok(existsSync(new URL(`../../app/(app)${h}/page.tsx`, import.meta.url)), h);
});

test("roles only see what they can open", () => {
  for (const h of ["/invoices/new", "/payments/new", "/settlements", "/dispatch-fee-invoices"]) {
    assert.equal(hrefAllowedForRole(h, "dispatcher"), false, h);
    assert.equal(hrefAllowedForRole(h, "accountant"), true, h);
  }
  for (const h of ["/billing/ready-to-bill", "/reports/revenue", "/collections?filter=disputed", "/accounts-receivable", "/settings/factoring"]) {
    assert.equal(hrefAllowedForRole(h, "dispatcher"), true, h);
    assert.equal(hrefAllowedForRole(h, "viewer"), false, h);
  }
  for (const h of ["/settings/users", "/settings/integrations", "/settings/subscription", "/settings/organization/bank-accounts"]) {
    assert.equal(hrefAllowedForRole(h, "admin"), true, h);
    assert.equal(hrefAllowedForRole(h, "dispatcher"), false, h);
  }
  for (const h of ["/loads/new", "/dispatch/board", "/tracking", "/carriers", "/settings/profile"]) assert.equal(hrefAllowedForRole(h, "viewer"), true, h);
  assert.match(toolbar, /const allowed = \(href: string\) => hrefAllowedForRole\(href, role\)/);
  assert.match(toolbar, /allowed\("\/invoices\/new"\) && <ToolbarLinkButton/);
});

test("menus follow the workflow; the collections shortcuts are one menu that does what it says", () => {
  const order = (text, labels) => {
    let at = -1;
    for (const l of labels) {
      const i = text.indexOf(`label: "${l}"`, at + 1);
      assert.ok(i > at, `${l} out of order`);
      at = i;
    }
  };
  const windowMenu = menuBar.slice(menuBar.indexOf('menu("Window"'), menuBar.indexOf('menu("Help"'));
  order(windowMenu, ["Dashboard", "Dispatch Board", "Loads", "Live Tracking", "Carriers", "Ready to Bill", "Invoices", "Dispatch Fee Invoices", "Payments", "Collections", "Carrier Settlements"]);
  assert.ok(!/label: "Factoring"/.test(menuBar), "the old Factoring workspace stays out of the menus");
  assert.ok(!/label: "Carrier Invoices"/.test(menuBar), "one Invoices tab");
  assert.match(toolbar, /\{ label: "Promises to pay", href: "\/collections\?status=promise_to_pay"/);
  assert.ok(!toolbar.includes("Log a promise to pay"));
  assert.match(toolbar, /href="\/tracking"/);
  assert.match(toolbar, /href="\/billing\/ready-to-bill"/);
});

test("no stray separators after hiding items", async () => {
  // visibleItems is exported from the client component; check its logic textually
  assert.match(menuBar, /if \(out\.length > 0 && out\[out\.length - 1\] !== "separator"\) out\.push\(item\)/);
  assert.match(menuBar, /while \(out\[out\.length - 1\] === "separator"\) out\.pop\(\)/);
});
