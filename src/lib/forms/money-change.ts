// Second safety net for money fields (after lib/forms/number-wheel.ts):
// when an edit form is saved and a guarded amount differs from the value
// that was loaded, the user must confirm the change -- an accidental edit
// (7,500.00 -> 7,499.31) is caught before it is stored.

export type MoneyChange = { label: string; from: number; to: number };

function toAmount(v: string | null | undefined): number | null {
  if (v === null || v === undefined || v.trim() === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

/** A guarded field changed if both the original and the new value are numbers and differ by at least a cent. */
export function moneyChange(label: string, original: string | null | undefined, current: string | null | undefined): MoneyChange | null {
  const from = toAmount(original);
  const to = toAmount(current);
  if (from === null || to === null) return null;
  return Math.round(from * 100) !== Math.round(to * 100) ? { label, from, to } : null;
}

const usd = (n: number) => n.toLocaleString("en-US", { style: "currency", currency: "USD" });

export function moneyChangeMessage(changes: MoneyChange[]): string {
  const lines = changes.map((c) => `${c.label} will change from ${usd(c.from)} to ${usd(c.to)}.`);
  return `${lines.join("\n")}\n\nSave this change?`;
}
