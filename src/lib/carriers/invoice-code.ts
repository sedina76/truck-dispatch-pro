// Suggests a carrier's invoice-number prefix (carriers.invoice_code, format
// ^[A-Z0-9][A-Z0-9-]{0,15}$) from its name, so nobody has to invent one:
// "Road Runner Trucking LLC" -> "RRT". Pure; the caller adds a number when
// the code is already taken in the organization.

const NOISE = new Set(["LLC", "INC", "CO", "CORP", "CORPORATION", "COMPANY", "LTD", "THE", "AND", "OF"]);

export function suggestInvoiceCode(name: string | null | undefined): string {
  const words = String(name ?? "")
    .toUpperCase()
    .replace(/[^A-Z0-9 ]+/g, " ")
    .split(/\s+/)
    .filter((w) => w && !NOISE.has(w));
  let code = words.length >= 2 ? words.slice(0, 4).map((w) => w[0]).join("") : (words[0] ?? "").slice(0, 4);
  if (!/^[A-Z0-9]/.test(code)) code = "CAR";
  if (code.length < 2) code = (code + (words[0] ?? "X").slice(1, 3) || "CAR").slice(0, 4) || "CAR";
  return code.slice(0, 12);
}

/** The code, or the code plus 2, 3, ... until it isn't in `taken`. */
export function uniqueInvoiceCode(base: string, taken: Iterable<string>): string {
  const used = new Set(Array.from(taken, (t) => t.toUpperCase()));
  if (!used.has(base)) return base;
  for (let n = 2; n < 1000; n++) {
    const c = `${base}${n}`.slice(0, 16);
    if (!used.has(c)) return c;
  }
  return `${base}-${Date.now() % 100000}`.slice(0, 16);
}
