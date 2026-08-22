import { redirect } from "next/navigation";
import { requireRoleForApi } from "@/lib/auth/require-role";
import { SetupPackageResourceNotFoundError } from "@/lib/carrier-setup-packages/errors";
import { getSetupPackageSignedUrlOrThrow } from "@/lib/carrier-setup-packages/signed-url";

export async function GET(request: Request, { params }: { params: Promise<{ packageId: string }> }) {
  const denied = await requireRoleForApi(["owner", "admin", "dispatcher", "accountant"]);
  if (denied) return denied;
  const { packageId } = await params;
  const download = new URL(request.url).searchParams.get("download") === "1";
  try {
    const { url } = await getSetupPackageSignedUrlOrThrow(packageId, download);
    redirect(url);
  } catch (error) {
    if (error instanceof SetupPackageResourceNotFoundError) {
      return new Response("Not Found", { status: 404 });
    }
    throw error;
  }
}
