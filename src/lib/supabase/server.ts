import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

// Use in Server Components, Route Handlers, and Server Actions. Cookie
// writes are wrapped in try/catch because Server Components cannot set
// cookies -- session refresh in that case is handled by middleware.ts.
//
// Not parameterized with the generated Database type yet -- see
// src/types/supabase.ts for why. Once real types are generated, add
// `createServerClient<Database>(...)` back for full query type safety.
export async function createClient() {
  const cookieStore = await cookies();

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options)
            );
          } catch {
            // Called from a Server Component -- ignore, middleware refreshes the session.
          }
        },
      },
    }
  );
}
