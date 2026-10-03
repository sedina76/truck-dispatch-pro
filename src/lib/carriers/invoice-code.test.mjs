import test from "node:test";
import assert from "node:assert/strict";
import { suggestInvoiceCode, uniqueInvoiceCode } from "./invoice-code.ts";

const FORMAT = /^[A-Z0-9][A-Z0-9-]{0,15}$/;

test("invoice code from the carrier name", () => {
  assert.equal(suggestInvoiceCode("Road Runner Trucking LLC"), "RRT");
  assert.equal(suggestInvoiceCode("Blue Line"), "BL");
  assert.equal(suggestInvoiceCode("Swift"), "SWIF");
  assert.equal(suggestInvoiceCode("A & B Transport, Inc."), "ABT");
  assert.equal(suggestInvoiceCode("  "), "CAR");
  for (const n of ["Road Runner Trucking LLC", "X", "123 Freight", "!!!", "J"]) assert.match(suggestInvoiceCode(n), FORMAT, n);
});

test("unique within the organization", () => {
  assert.equal(uniqueInvoiceCode("RRT", ["ABC"]), "RRT");
  assert.equal(uniqueInvoiceCode("RRT", ["rrt", "RRT2"]), "RRT3");
});
