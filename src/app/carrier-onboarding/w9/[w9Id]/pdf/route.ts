import { NextRequest, NextResponse } from "next/server";
import { getCarrierOnboardingSession } from "@/lib/carrier-onboarding/session";
import { getMyW9Url } from "../../../actions";

// Mirrors src/app/carrier-onboarding/agreement/[signingId]/pdf/route.ts
// exactly: generic 404 for no session, foreign application, random UUID,
// or a not-yet-completed W-9 alike -- no existence leak.
export async function GET(request: NextRequest, { params }: { params: Promise<{ w9Id: string }> }) {
  const identity = await getCarrierOnboardingSession();
  if (!identity) return new NextResponse("Not found", { status: 404 });
  const { w9Id } = await params;
  const result = await getMyW9Url(w9Id, request.nextUrl.searchParams.get("download") === "1");
  if (!result.ok) return new NextResponse("Not found", { status: 404 });
  return NextResponse.redirect(result.url, 307);
}
