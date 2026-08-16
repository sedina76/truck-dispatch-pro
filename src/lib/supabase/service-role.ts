import "server-only";
import { createClient as createSupabaseClient } from "@supabase/supabase-js";

// Bypasses RLS entirely -- use only from trusted server-side code (route
// handlers, server actions) that has already independently verified the
// caller's identity. The driver portal is the one place this is needed:
// drivers authenticate with a phone + PIN, not Supabase Auth, so there is no
// JWT for RLS/auth.uid() to key off of. Never import this into client code.
export function createServiceRoleClient() {
  return createSupabaseClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { auth: { autoRefreshToken: false, persistSession: false } }
  );
}
