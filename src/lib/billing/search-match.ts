// Forgiving search for invoice and load numbers: plain case-insensitive
// "contains", plus a digits-only match so "LD-00039", "100039" or "39" in
// "ld 39" still find LD-100039 (typed prefixes, dashes and dropped digits
// are common when reading a number off a rate confirmation).

const digits = (s: string) => s.replace(/\D/g, "");

export function matchesSearch(text: string | null | undefined, query: string | null | undefined): boolean {
  const q = (query ?? "").trim().toLowerCase();
  if (!q) return true;
  const t = (text ?? "").toLowerCase();
  if (t.includes(q)) return true;
  const qd = digits(q).replace(/^0+/, "");
  const td = digits(t);
  return qd.length >= 2 && td.length > 0 && td.endsWith(qd);
}

/** Makes a search term safe inside a PostgREST or() filter (no commas, parentheses or wildcards from the user). */
export function safeFilterTerm(q: string): string {
  return q.replace(/[,()%*\\]/g, " ").trim();
}
