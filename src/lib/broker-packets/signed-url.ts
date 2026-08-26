import "server-only";

import { getCurrentOrgId } from "@/lib/actions/records";
import { createClient } from "@/lib/supabase/server";
import { BROKER_PACKET_BUCKET, brokerPacketStoragePath } from "./types";

export class BrokerPacketResourceNotFoundError extends Error {
  constructor() {
    super("Broker packet not found.");
  }
}

// View/Download roles per 2M.2B decision 2: Owner/Admin/Dispatcher/
// Accountant may read the artifact; Viewer sees packet metadata elsewhere
// (broker_packets_select RLS) but never reaches this function's caller.
// Driver has no Broker Packet access at all.
const DOWNLOAD_ROLES = new Set(["owner", "admin", "dispatcher", "accountant"]);

export async function getBrokerPacketSignedUrlOrThrow(packetId: string, download: boolean): Promise<{ url: string; filename: string }> {
  const supabase = await createClient();
  const [{ data: { user } }, { data: role }] = await Promise.all([supabase.auth.getUser(), supabase.rpc("current_role")]);
  if (!user || !DOWNLOAD_ROLES.has(String(role))) throw new BrokerPacketResourceNotFoundError();

  const organizationId = await getCurrentOrgId();
  const { data } = await supabase
    .from("broker_packets")
    .select("id, organization_id, broker_id, version, status, generated_storage_path, generated_pdf_sha256")
    .eq("id", packetId)
    .maybeSingle();
  if (!data || data.organization_id !== organizationId || !["generated", "sent", "superseded"].includes(data.status) || !data.generated_storage_path || !data.generated_pdf_sha256) {
    throw new BrokerPacketResourceNotFoundError();
  }

  const expected = brokerPacketStoragePath(data);
  if (data.generated_storage_path !== expected) throw new Error("Broker packet storage path is invalid.");
  const filename = `broker-packet-v${data.version}.pdf`;
  const { data: signed, error } = await supabase.storage.from(BROKER_PACKET_BUCKET).createSignedUrl(expected, 300, download ? { download: filename } : undefined);
  if (error || !signed) throw new Error("Could not create a secure broker packet link.");
  return { url: signed.signedUrl, filename };
}
