import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { resolveBillingAccess } from "@/lib/billing/access-policy";

const PUBLIC_PATHS = [
  "/login",
  "/signup",
  // Auth redesign: verify-email/forgot-password/reset-password/forgot-email
  // must be reachable with NO session at all (that's the entire point of
  // each of them), and /auth/callback is the PKCE code-exchange endpoint a
  // password-recovery email link lands on before any session exists yet.
  // /reset-password specifically also needs to stay public so an
  // already-expired/already-used recovery link can render its OWN honest
  // "link expired" message (spec section 13) instead of being
  // 307-redirected to /login before the page ever gets a chance to check.
  "/verify-email",
  "/forgot-password",
  "/reset-password",
  "/forgot-email",
  "/auth/callback",
  "/driver-portal",
  "/api/driver-portal",
  "/driver-application",
  "/api/driver-application",
  // Carrier onboarding is invitation/session mediated rather than staff-
  // authenticated. Its route handlers, portal layout, and server actions
  // validate the invitation or carrier_onboarding_session after middleware.
  "/carrier-onboarding",
  // Phase 2F: Resend's webhook POST carries no Supabase session cookie at
  // all -- it authenticates via its own Svix signature (see
  // src/app/api/webhooks/resend/route.ts), never a logged-in user. Found
  // live: without this exemption, the middleware 307-redirected every
  // webhook delivery to /login before it ever reached the route handler,
  // meaning delivery-status tracking would have silently never worked in
  // production. Scoped to exactly this one route (not a broader
  // /api/webhooks prefix, spec review item 7) -- there is no general
  // webhook-auth architecture in this app yet, so this stays as narrow as
  // what actually exists.
  "/api/webhooks/resend",
  // Phase D.2.2: same rationale as /api/webhooks/resend. Stripe's signed
  // webhook POST (src/app/api/webhooks/stripe/route.ts) carries no Supabase
  // session cookie -- it authenticates via Stripe-Signature +
  // STRIPE_WEBHOOK_SECRET + stripe.webhooks.constructEvent, verified by the
  // route BEFORE any DB work. "Public" here means only "the request may
  // reach the route" -- NOT "trusted". matchesPath() matches this exact
  // pathname and, by its trailing-slash prefix rule, any /api/webhooks/
  // stripe/<child> (none exist: that directory holds only route.ts).
  // Deliberately NOT "/api/webhooks" -- /api/webhooks/resend keeps its own
  // entry and every other /api/webhooks/* stays authenticated.
  "/api/webhooks/stripe",
];

// Paths a tenant whose billing has lapsed may still reach, so they can
// actually recover (see why they're blocked, re-subscribe, sign out) instead
// of hitting a redirect loop. Deliberately NARROW -- no operational area
// (/loads, /dispatch, /invoices, /payments, /settlements, /compliance,
// /quickbooks, ...) is here.
//   /settings/subscription -- the billing/recovery page itself, and the
//     Stripe Checkout success/cancel return target (?checkout=complete|
//     canceled). Its own server action re-checks owner/admin.
//   /onboarding -- setup-only surface; a new self-service org may still be
//     finishing setup while its billing row is pending. Not operational.
//   /admin -- the platform console (src/app/(superadmin)/**). It has its
//     OWN hard guard: (superadmin)/layout.tsx redirects anyone who is not
//     is_platform_admin to /dashboard. Platform admins carry
//     organization_id = null, so the billing gate below never evaluates for
//     them anyway; this entry only keeps a dual-role admin (platform admin
//     who also belongs to a billing-lapsed org) able to reach the console.
//     An ordinary org user who lands here is still bounced by that layout.
//   ...PUBLIC_PATHS -- /login, /auth/callback, the signed webhook endpoints,
//     etc. Session-cookie refresh happens at the top of updateSession,
//     before any gate, so sign-out/session maintenance always works.
const SUBSCRIPTION_GATE_EXEMPT_PATHS = [
  "/settings/subscription",
  "/onboarding",
  "/admin",
  ...PUBLIC_PATHS,
];

function matchesPath(pathname: string, path: string): boolean {
  return pathname === path || pathname.startsWith(`${path}/`);
}

// Refreshes the Supabase auth session on every request, redirects
// unauthenticated users away from the (app) route group, and -- via the
// authoritative resolver in src/lib/billing/access-policy.ts -- redirects a
// tenant without full billing access to /settings/subscription, leaving only
// the narrow recovery paths reachable. Called from the root middleware.ts.
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

  const isPublicPath = PUBLIC_PATHS.some((path) => matchesPath(request.nextUrl.pathname, path));

  if (!user && !isPublicPath) {
    const loginUrl = request.nextUrl.clone();
    loginUrl.pathname = "/login";
    return NextResponse.redirect(loginUrl);
  }

  const isGateExempt = SUBSCRIPTION_GATE_EXEMPT_PATHS.some((path) => matchesPath(request.nextUrl.pathname, path));

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
      // Minimum facts for the authoritative resolver. Both reads are on the
      // RLS-scoped anon client (never service-role) and keyed on the
      // authenticated profile's org id -- never a browser-supplied id.
      const [orgResult, subscriptionResult] = await Promise.all([
        supabase
          .from("organizations")
          .select("billing_required")
          .eq("id", profile.organization_id)
          .maybeSingle(),
        supabase
          .from("organization_subscriptions")
          .select("status, grandfathered_at, past_due_since")
          .eq("organization_id", profile.organization_id)
          .maybeSingle(),
      ]);

      if (orgResult.error || subscriptionResult.error) {
        // Same convention as the profile read above: a real query error is
        // "backend unreachable", not "no access".
        const maintenanceUrl = request.nextUrl.clone();
        maintenanceUrl.pathname = "/service-unavailable";
        return NextResponse.redirect(maintenanceUrl);
      }

      const org = orgResult.data as { billing_required: boolean } | null;
      const subscription = subscriptionResult.data as {
        status: string | null;
        grandfathered_at: string | null;
        past_due_since: string | null;
      } | null;

      const decision = resolveBillingAccess({
        billingRequired: org?.billing_required === true,
        subscriptionExists: subscription !== null,
        grandfatheredAt: subscription?.grandfathered_at ?? null,
        status: subscription?.status ?? null,
        pastDueSince: subscription?.past_due_since ?? null,
        now: new Date(),
      });

      if (decision.access === "billing_only") {
        const blockedUrl = request.nextUrl.clone();
        blockedUrl.pathname = "/settings/subscription";
        return NextResponse.redirect(blockedUrl);
      }
    }
  }

  return response;
}
