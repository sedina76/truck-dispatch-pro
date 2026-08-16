import { createBrowserClient } from "@supabase/ssr";

// Not parameterized with the generated Database type yet -- see
// src/types/supabase.ts for why. Once real types are generated, add
// `createBrowserClient<Database>(...)` back for full query type safety.
export function createClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  );
}
