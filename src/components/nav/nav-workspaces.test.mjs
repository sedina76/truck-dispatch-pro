// Simpler sidebar: related pages are tabs inside one entry. Every old page
// address still works and highlights the right sidebar entry and tab.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { WORKSPACES, workspaceFor, navItemActive } from "./workspaces.ts";

// Sidebar entries read from nav-config.ts (it imports icons, which need React).
const cfg = readFileSync(new URL("./nav-config.ts", import.meta.url), "utf8");
const sectionsSrc = cfg.slice(cfg.indexOf("export const SECTIONS"), cfg.indexOf("// Shared by both Sidebar"));
const BILLING = ["/billing", "/invoices", "/carrier-invoices", "/payments", "/accounts-receivable", "/collections", "/statements"];
const items = [...sectionsSrc.matchAll(/\{ label: "([^"]+)", href: "([^"]+)"[^\n]*/g)].map((m) => {
  const match = m[0].match(/match: (\[[^\]]*\]|BILLING_WORKSPACE_PREFIXES)/);
  return { label: m[1], href: m[2], match: !match ? undefined : match[1] === "BILLING_WORKSPACE_PREFIXES" ? BILLING : JSON.parse(match[1]) };
});

const entryFor = (path) => items.filter((i) => navItemActive(i, path)).map((i) => i.label);

test("the sidebar is short", () => {
  assert.ok(items.length >= 15 && items.length <= 18, `${items.length} entries`);
});

test("every page that lost its own entry is still reachable as a tab and lights up exactly one entry", () => {
  const moved = ["/dispatch/exceptions", "/drivers/applications", "/trailers", "/fuel", "/carriers/onboarding", "/customers", "/settlements", "/driver-settlements", "/advances", "/compliance", "/email-history", "/settings/users", "/settings/email", "/settings/integrations", "/settings/factoring"];
  for (const path of moved) {
    assert.ok(workspaceFor(path), `${path} has a tab row`);
    assert.equal(entryFor(path).length, 1, `${path} -> ${entryFor(path)}`);
  }
});

test("longest match wins: detail and sub pages pick the right tab", () => {
  assert.equal(workspaceFor("/drivers/applications/abc").active, "/drivers/applications");
  assert.equal(workspaceFor("/drivers/123").active, "/drivers");
  assert.equal(workspaceFor("/carriers/onboarding/x").active, "/carriers/onboarding");
  assert.equal(workspaceFor("/carriers/abc").active, "/carriers");
  assert.equal(workspaceFor("/dispatch/new").active, "/dispatch/board");
  assert.equal(workspaceFor("/dispatch-fee-invoices"), null);
  assert.equal(workspaceFor("/loads"), null);
  assert.deepEqual(entryFor("/dispatch-fee-invoices"), ["Dispatch Fee Invoices"]);
  assert.deepEqual(entryFor("/invoices/abc"), ["Billing"]);
  assert.deepEqual(entryFor("/dashboard"), ["Dashboard"]);
});

test("each workspace tab appears once", () => {
  const hrefs = WORKSPACES.flatMap((w) => w.tabs.map((t) => t.href));
  assert.equal(new Set(hrefs).size, hrefs.length);
});
