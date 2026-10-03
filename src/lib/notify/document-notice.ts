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
