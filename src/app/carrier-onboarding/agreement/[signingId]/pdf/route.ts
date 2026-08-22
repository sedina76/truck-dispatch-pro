import { NextRequest, NextResponse } from "next/server";
import { getCarrierOnboardingSession } from "@/lib/carrier-onboarding/session";
import { getCarrierExecutedAgreementSignedUrl } from "@/lib/carrier-agreements/signed-url";
import { ExecutedAgreementResourceNotFoundError } from "@/lib/carrier-agreements/errors";

export async function GET(request: NextRequest, { params }: { params: Promise<{ signingId: string }> }) {
  const identity = await getCarrierOnboardingSession();
  if (!identity) return new NextResponse("Not found", { status: 404 });
  const { signingId } = await params;
  try {
    const result = await getCarrierExecutedAgreementSignedUrl(identity.applicationId, signingId, request.nextUrl.searchParams.get("download") === "1");
    return NextResponse.redirect(result.url, 307);
  } catch (error) {
    if (error instanceof ExecutedAgreementResourceNotFoundError) return new NextResponse("Not found", { status: 404 });
    throw error;
  }
}
