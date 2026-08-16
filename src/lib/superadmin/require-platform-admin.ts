import "server-only";
import { createClient } from "@/lib/supabase/server";

// Single canonical server-side authorization check, used by EVERY
// platform-admin mutation across the console (company profile edits,
// admin/credential management, subscription changes, suspend/reactivate).
// The (superadmin) layout already gates page RENDERS, but per-action
// re-verification is required here too -- a Server Action is a public HTTP
// endpoint in its own right (Next.js exposes it as one), reachable
// directly regardless of which page rendered the button that called it.
// This mirrors is_platform_admin() (0016), the same SECURITY DEFINER
// function the layout itself calls, so there is exactly one source of
// truth for "is this caller a platform admin" -- never re-derived.
export async function requirePlatformAdmin() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("is_platform_admin");
  if (error || !data) throw new Error("Not authorized.");
  return supabase;
}
