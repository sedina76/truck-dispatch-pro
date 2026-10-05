// Sign in / sign up with an existing Google or Microsoft account (Supabase
// OAuth). A provider shows up only once it is switched on for this
// deployment -- NEXT_PUBLIC_AUTH_PROVIDERS="google,azure" -- because a
// button for a provider not yet enabled in Supabase would just fail.
// Pure; shared by the buttons and tests.

export type OAuthProvider = "google" | "azure";

export const PROVIDER_LABEL: Record<OAuthProvider, string> = { google: "Google", azure: "Microsoft" };

export function enabledProviders(raw: string | undefined): OAuthProvider[] {
  const out: OAuthProvider[] = [];
  for (const p of (raw ?? "").split(",").map((s) => s.trim().toLowerCase())) {
    const id = p === "microsoft" ? "azure" : p;
    if ((id === "google" || id === "azure") && !out.includes(id)) out.push(id);
  }
  return out;
}

/** Only same-site paths are allowed as the place to land after sign-in. */
export function safeNext(next: string | null | undefined, fallback = "/dashboard"): string {
  if (!next || !next.startsWith("/") || next.startsWith("//") || next.startsWith("/\\")) return fallback;
  return next;
}
