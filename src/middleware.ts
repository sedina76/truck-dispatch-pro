import { NextResponse, type NextRequest } from "next/server";
import { updateSession } from "@/lib/supabase/middleware";
import { maintenanceGate } from "@/lib/maintenance/gate";

// Preserve the previous matcher's session-refresh exclusions when the gate passes.
const LEGACY_SESSION_EXCLUSION = /^\/(?:_next\/static|_next\/image|favicon.ico|.*\.(?:svg|png|jpg|jpeg|gif|webp)$)/;

export async function middleware(request: NextRequest) {
  // Match every path so application tokens and non-GET asset requests reach the gate.
  const maintenance = maintenanceGate(request, process.env);
  if (maintenance) return maintenance;
  if (LEGACY_SESSION_EXCLUSION.test(request.nextUrl.pathname)) {
    return NextResponse.next({ request });
  }
  return updateSession(request);
}

// Every path EXCEPT Next's own immutable build files (/_next/static/...) and
// the favicon: those are served straight from the CDN, never accept writes,
// and running edge middleware on each one only adds latency and cost to
// every page load. Everything else -- pages, APIs, server actions, the image
// optimizer, image-suffixed app URLs like /carrier-onboarding/<token>.png --
// still reaches the maintenance gate.
export const config = {
  matcher: ["/((?!_next/static/|favicon\\.ico$).*)"],
};
