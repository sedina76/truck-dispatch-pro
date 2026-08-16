// Coerces an empty-string form field to null (Postgres numeric/date columns
// reject "" but accept null for optional fields).
export function emptyToNull(value: FormDataEntryValue | null): string | null {
  if (value === null) return null;
  const str = String(value).trim();
  return str === "" ? null : str;
}

// PostgREST requires JSON numbers (not numeric strings) for numeric/integer
// columns, so numeric form fields must be coerced before being sent.
export function toNumber(value: FormDataEntryValue | null): number | null {
  if (value === null) return null;
  const str = String(value).trim();
  if (str === "") return null;
  const num = Number(str);
  return Number.isNaN(num) ? null : num;
}
