// What the office sees in the bell when a driver uploads a document from the
// Driver Portal. Pure (unit-tested); the insert lives in office-notify.ts.

const LABELS: Record<string, { short: string; long: string }> = {
  pod: { short: "POD", long: "a proof of delivery" },
  bol: { short: "BOL", long: "a bill of lading" },
  lumper_receipt: { short: "Lumper receipt", long: "a lumper receipt" },
  scale_ticket: { short: "Scale ticket", long: "a scale ticket" },
  fuel_receipt: { short: "Fuel receipt", long: "a fuel receipt" },
  other: { short: "Document", long: "a document" },
};

export function driverDocumentNotice(documentType: string, loadNumber: string | null, driverName: string | null): { title: string; body: string } {
  const l = LABELS[documentType] ?? LABELS.other;
  const load = loadNumber ? `Load ${loadNumber}` : "a load";
  const who = driverName?.trim() || "The driver";
  return {
    title: `${l.short} uploaded -- ${load}`,
    body: `${who} uploaded ${l.long}${documentType === "pod" ? ". Review and verify it so the load can be billed." : "."}`,
  };
}

const EXPENSE_LABEL: Record<string, string> = {
  fuel: "Fuel",
  lumper: "Lumper",
  tolls: "Toll",
  scale_ticket: "Scale ticket",
  parking: "Parking",
  permit: "Permit",
  washout: "Washout",
  other: "Other",
};

/** Bell text when a driver submits an expense from the Driver Portal. */
export function driverExpenseNotice(category: string, amount: number, loadNumber: string | null, driverName: string | null, vendor: string | null): { title: string; body: string } {
  const label = EXPENSE_LABEL[category] ?? category.replace(/_/g, " ");
  const money = `$${Number(amount).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  const load = loadNumber ? `Load ${loadNumber}` : "a load";
  const who = driverName?.trim() || "The driver";
  return {
    title: `${label} expense ${money} -- ${load}`,
    body: `${who} submitted it${vendor ? ` (${vendor})` : ""}. Check the receipt and approve it.`,
  };
}

/** Bell text when a driver logs a fuel purchase from the Driver Portal. */
export function driverFuelNotice(p: { amount: number; gallons: number; station: string | null; truckUnit: string | null; loadNumber: string | null; paidByLabel: string; driverName: string | null }): { title: string; body: string } {
  const money = `$${Number(p.amount).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  const gal = `${Number(p.gallons).toLocaleString("en-US", { maximumFractionDigits: 2 })} gal`;
  const truck = p.truckUnit ? `Truck ${p.truckUnit}` : "a truck";
  const who = p.driverName?.trim() || "The driver";
  return {
    title: `Fuel ${money} (${gal}) -- ${truck}`,
    body: `${who} logged it${p.station ? ` at ${p.station}` : ""}${p.loadNumber ? ` on Load ${p.loadNumber}` : ""}. Paid with: ${p.paidByLabel}.`,
  };
}
