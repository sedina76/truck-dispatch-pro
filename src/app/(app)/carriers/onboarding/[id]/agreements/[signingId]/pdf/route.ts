import { NextRequest, NextResponse } from "next/server";
import { getStaffExecutedAgreementSignedUrl } from "@/lib/carrier-agreements/signed-url";
import { ExecutedAgreementAccessDeniedError, ExecutedAgreementResourceNotFoundError } from "@/lib/carrier-agreements/errors";

export async function GET(request: NextRequest, { params }: { params: Promise<{ id: string; signingId: string }> }) {
  const { id, signingId } = await params;
  try {
    const result = await getStaffExecutedAgreementSignedUrl(id, signingId, request.nextUrl.searchParams.get("download") === "1");
    return NextResponse.redirect(result.url, 307);
  } catch (error) {
    if (error instanceof ExecutedAgreementResourceNotFoundError) return new NextResponse("Not found", { status: 404 });
    if (error instanceof ExecutedAgreementAccessDeniedError) return new NextResponse("Forbidden", { status: 403 });
    throw error;
  }
}
