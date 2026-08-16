import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

const PUBLIC_PATHS = [
  "/login",
  "/signup",
  "/driver-portal",
  "/api/driver-portal",
  "/driver-application",
  "/api/driver-application",
];

// Paths that must stay reachable even for a blocked (past_due/paused/
// canceled/incomplete) tenant -- otherwise there'd be no way to see why
// they're blocked, or for a platform admin (no organization_id) to reach
// their own console.
const SUBSCRIPTION_GATE_EXEMPT_PATHS = [
  "/settings/subscription",
  "/onboarding",
  "/admin",
  ...PUBLIC_PATHS,
];

const BLOCKED_SUBSCRIPTION_STATUSES = ["past_due", "paused", "canceled", "incomplete"];

// Refreshes the Supabase auth session on every request, redirects
// unauthenticated users away from the (app) route group, and blocks a
// tenant whose subscription has lapsed from everything except the page
// that explains why. Called from the root middleware.ts.
export async function updateSession(request: NextRequest) {
  // /service-unavailable itself must never depend on Supabase being reachable --
  // it's the one page that has to render when the backend is down.
  if (request.nextUrl.pathname.startsWith("/service-unavailable")) {
    return NextResponse.next({ request });
  }

  let response = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options)
          );
        },
      },
    }
  );

  // supabase-js does NOT throw when the network request itself fails (DNS
  // failure, paused/deleted project, ...) -- it catches that internally and
  // resolves normally with `data.user = null` and an AuthError whose message
  // is the raw fetch failure. A try/catch around this call never fires, so
  // detect that case explicitly and treat it as "backend unreachable," not
  // "visitor isn't logged in" (which would otherwise just bounce everyone to
  // /login with no explanation, or -- for pages that then try their own
  // Supabase queries -- surface as a raw crash).
  const { data, error } = await supabase.auth.getUser();
  if (error && /fetch failed|ENOTFOUND|ECONNREFUSED|network/i.test(error.message)) {
    const maintenanceUrl = request.nextUrl.clone();
    maintenanceUrl.pathname = "/service-unavailable";
    return NextResponse.redirect(maintenanceUrl);
  }
  const user = data.user;

  const isPublicPath = PUBLIC_PATHS.some((path) => request.nextUrl.pathname.startsWith(path));

  if (!user && !isPublicPath) {
    const loginUrl = request.nextUrl.clone();
    loginUrl.pathname = "/login";
    return NextResponse.redirect(loginUrl);
  }

  const isGateExempt = SUBSCRIPTION_GATE_EXEMPT_PATHS.some((path) => request.nextUrl.pathname.startsWith(path));

  if (user && !isGateExempt) {
    // Same reasoning as above: the postgrest-js client also resolves with
    // {data: null, error} rather than throwing on a network failure.
    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("organization_id")
      .eq("id", user.id)
      .maybeSingle();

    if (profileError) {
      const maintenanceUrl = request.nextUrl.clone();
      maintenanceUrl.pathname = "/service-unavailable";
      return NextResponse.redirect(maintenanceUrl);
    }

    if (profile?.organization_id) {
      const { data: subscription } = await supabase
        .from("organization_subscriptions")
        .select("status")
        .eq("organization_id", profile.organization_id)
        .maybeSingle();

      if (subscription && BLOCKED_SUBSCRIPTION_STATUSES.includes(subscription.status)) {
        const blockedUrl = request.nextUrl.clone();
        blockedUrl.pathname = "/settings/subscription";
        return NextResponse.redirect(blockedUrl);
      }
    }
  }

  return response;
}
