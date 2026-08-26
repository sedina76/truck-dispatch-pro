import { redirect } from "next/navigation";
import { requireRoleForApi } from "@/lib/auth/require-role";
import { BrokerPacketResourceNotFoundError, getBrokerPacketSignedUrlOrThrow } from "@/lib/broker-packets/signed-url";

// Shape-complete now; harmless until generation exists (2M.2B defers the
// render/upload/finalize step to the next checkpoint), since no packet can
// reach status='generated' without finalize_broker_packet() being called
// from application code, which does not happen yet. Mirrors the setup
// package pdf route exactly (src/app/(app)/carriers/onboarding/[id]/
// setup-packages/[packageId]/pdf/route.ts).
export async function GET(request: Request, { params }: { params: Promise<{ packetId: string }> }) {
  const denied = await requireRoleForApi(["owner", "admin", "dispatcher", "accountant"]);
  if (denied) return denied;
  const { packetId } = await params;
  const download = new URL(request.url).searchParams.get("download") === "1";
  try {
    const { url } = await getBrokerPacketSignedUrlOrThrow(packetId, download);
    redirect(url);
  } catch (error) {
    if (error instanceof BrokerPacketResourceNotFoundError) return new Response("Not Found", { status: 404 });
    throw error;
  }
}
