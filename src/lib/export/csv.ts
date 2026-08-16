// Shared CSV generation -- every Export route builds its output through
// this, so quoting/escaping/date-formatting is identical everywhere
// instead of each route hand-rolling its own join(",").

export type CsvColumn<T> = {
  header: string;
  /** Return a primitive; numbers/dates are formatted consistently below. */
  value: (row: T) => string | number | null | undefined;
};

function escapeCell(raw: string | number | null | undefined): string {
  if (raw === null || raw === undefined) return "";
  const s = typeof raw === "number" ? String(raw) : raw;
  // Quote whenever the value contains a comma, quote, or newline -- doubling
  // any embedded quotes, per RFC 4180.
  if (/[",\n\r]/.test(s)) {
    return `"${s.replace(/"/g, '""')}"`;
  }
  return s;
}

export function toCsv<T>(rows: T[], columns: CsvColumn<T>[]): string {
  const header = columns.map((c) => escapeCell(c.header)).join(",");
  const lines = rows.map((row) => columns.map((c) => escapeCell(c.value(row))).join(","));
  // UTF-8 BOM so Excel (Windows) opens non-ASCII characters correctly
  // instead of guessing the wrong codepage.
  return "﻿" + [header, ...lines].join("\r\n") + "\r\n";
}

export function csvResponse(csv: string, filenameBase: string): Response {
  const date = new Date().toISOString().slice(0, 10);
  return new Response(csv, {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="${filenameBase}-${date}.csv"`,
    },
  });
}

export function formatMoney(n: number | null | undefined): number | null {
  if (n === null || n === undefined) return null;
  return Math.round(Number(n) * 100) / 100;
}

export function formatDate(d: string | null | undefined): string {
  if (!d) return "";
  // Dates from Postgres `date` columns are already "YYYY-MM-DD" -- pass
  // through as-is rather than re-parsing through the local Date object
  // (which can shift by a day depending on the server's timezone).
  return d.length >= 10 ? d.slice(0, 10) : d;
}
