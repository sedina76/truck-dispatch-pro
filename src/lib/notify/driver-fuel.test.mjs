// Fuel a driver submits goes to Fuel Logs (per truck: gallons, price, state,
// odometer, who paid) with a receipt, and the office is notified with a link
// to that fuel log. Other expense categories still go to Expenses.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { driverFuelNotice } from "./document-notice.ts";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("bell text for driver fuel", () => {
  assert.deepEqual(
    driverFuelNotice({ amount: 412.5, gallons: 110.25, station: "Pilot Flying J", truckUnit: "T-101", loadNumber: "LD-000001", paidByLabel: "Carrier fuel card", driverName: "Ali Salah" }),
    { title: "Fuel $412.50 (110.25 gal) -- Truck T-101", body: "Ali Salah logged it at Pilot Flying J on Load LD-000001. Paid with: Carrier fuel card." }
  );
});

test("fuel -> fuel_logs (not expenses), receipt on the fuel log, office notified", () => {
  const a = src("../../app/driver-portal/actions.ts");
  const submit = a.slice(a.indexOf("export async function submitDriverExpense"), a.indexOf("async function submitDriverFuel"));
  const fuelBranch = submit.indexOf('if (category === "fuel")');
  assert.ok(fuelBranch > 0 && fuelBranch < submit.indexOf('.from("expenses")'), "fuel returns before any expense insert");
  const fuel = a.slice(a.indexOf("async function submitDriverFuel"), a.indexOf("export async function uploadDriverFuelReceipt"));
  assert.match(fuel, /\.from\("fuel_logs"\)\s+\.insert\(\{/);
  assert.match(fuel, /truck_id: trip\.truck_id,\s+driver_id: identity\.driverId,/);
  assert.match(fuel, /if \(!gallons \|\| gallons <= 0\) throw new Error\("Enter the gallons\."\)/);
  assert.match(fuel, /await notifyOfficeOfDriverFuel\(supabase, \{/);
  const up = a.slice(a.indexOf("export async function uploadDriverFuelReceipt"), a.indexOf("export async function getDriverFuelReceiptSignedUrl"));
  assert.match(up, /log\.driver_id !== identity\.driverId/);
  assert.match(up, /entity_type: "fuel",[\s\S]*document_type: "fuel_receipt"/);
  assert.match(up, /update\(\{ receipt_document_id: doc\.id \}\)/);
  const url = a.slice(a.indexOf("export async function getDriverFuelReceiptSignedUrl"));
  assert.match(url, /if \(!log \|\| log\.driver_id !== identity\.driverId\) throw new Error\("Document not found\."\)/);
  assert.match(src("./office-notify.ts"), /entity_type: "fuel" as const,\s+entity_id: p\.fuelLogId/);
  assert.match(src("../../components/nav/notifications-menu.tsx"), /n\.entity_type === "fuel" \? `\/fuel\/\$\{n\.entity_id\}`/);
  assert.match(src("../../app/(app)/dispatch/message-alert-actions.ts"), /row\.entity_type === "fuel" \? `\/fuel\/\$\{row\.entity_id\}`/);
});

test("driver app: fuel fields, own fuel list and detail", () => {
  const form = src("../../components/driver-portal/new-expense-form.tsx");
  for (const f of ['name="gallons"', 'name="price_per_gallon"', 'name="state"', 'name="odometer_reading"', 'name="paid_by"']) assert.ok(form.includes(f), f);
  assert.match(form, /router\.push\(fuelLogId \? `\/driver-portal\/expenses\/fuel\/\$\{fuelLogId\}`/);
  const list = src("../../app/driver-portal/expenses/page.tsx");
  assert.match(list, /\.from\("fuel_logs"\)[\s\S]*\.eq\("driver_id", identity\.driverId\)/);
  const detail = src("../../app/driver-portal/expenses/fuel/[id]/page.tsx");
  assert.match(detail, /\.eq\("driver_id", identity\.driverId\)/);
  assert.match(detail, /<ExpenseReceiptUpload fuelLogId=\{f\.id\} \/>/);
});
