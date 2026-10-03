import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { matchesSearch, safeFilterTerm } from "./search-match.ts";

test("finds a load by its number even when typed loosely", () => {
  for (const q of ["LD-100039", "ld-100039", "100039", "LD-00039", "00039", "39", "LD-1000"]) assert.equal(matchesSearch("LD-100039", q), true, q);
  for (const q of ["LD-100038", "LD-200039", "LD-0038", "xyz"]) assert.equal(matchesSearch("LD-100039", q), false, q);
  assert.equal(matchesSearch("anything", ""), true);
  assert.equal(matchesSearch(null, "39"), false);
});

test("search terms cannot break the database filter", () => {
  assert.equal(safeFilterTerm("LD-1,status.eq.paid)"), "LD-1 status.eq.paid");
  assert.equal(safeFilterTerm("%*"), "");
});

test("Invoices list and Create Invoice search by load number", () => {
  const page = readFileSync(new URL("../../app/(app)/invoices/page.tsx", import.meta.url), "utf8");
  assert.match(page, /load_id\.in\.\(/);
  assert.match(page, /Search by invoice #, load #, or bill-to name/);
  const picker = readFileSync(new URL("../../components/invoices/load-picker.tsx", import.meta.url), "utf8");
  assert.equal((picker.match(/matchesSearch\(l\.load_number, q\)/g) ?? []).length, 2);
});
