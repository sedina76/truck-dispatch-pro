// Remembers the phone number a driver signs in with on this device, so the
// next sign-in only needs the PIN. Browser storage can be unavailable
// (private mode, blocked site data), so every access is guarded and the
// screens work the same without it. Only the phone number is stored --
// never the PIN.
const KEY = "tdp.driver-portal.phone";

export function rememberedPhone(): string {
  try {
    return window.localStorage.getItem(KEY) ?? "";
  } catch {
    return "";
  }
}

export function rememberPhone(phone: string) {
  try {
    window.localStorage.setItem(KEY, phone);
  } catch {
    // storage blocked -- nothing to remember, nothing breaks
  }
}
