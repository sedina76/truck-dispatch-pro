// Display a phone number the way people read it: 6193650072 -> (619) 365-0072,
// +1 619 365 0072 -> (619) 365-0072. Anything that isn't a 10-digit US/Canada
// number (after an optional leading 1) is shown exactly as stored.
export function formatPhone(raw: string | null | undefined): string {
  if (!raw) return "--";
  const digits = raw.replace(/\D/g, "");
  const ten = digits.length === 11 && digits.startsWith("1") ? digits.slice(1) : digits;
  if (ten.length !== 10) return raw.trim();
  return `(${ten.slice(0, 3)}) ${ten.slice(3, 6)}-${ten.slice(6)}`;
}
