import "server-only";
import type { createClient } from "@/lib/supabase/server";

// Where a carrier's invoice billing packet is saved: the private
// billing-packets bucket, under the organization's folder (the bucket's RLS
// scopes by that first folder; only owner/admin/accountant may write).
// One current copy per invoice -- older copies are removed when a new one is saved.

type Supabase = Awaited<ReturnType<typeof createClient>>;
const BUCKET = "billing-packets";

export const packetFolder = (orgId: string, invoiceId: string) => `${orgId}/carrier-invoices/${invoiceId}`;

export async function saveCarrierPacket(supabase: Supabase, orgId: string, invoiceId: string, bytes: Uint8Array, filename: string): Promise<{ path: string } | { error: string }> {
  const folder = packetFolder(orgId, invoiceId);
  const path = `${folder}/${Date.now()}-${filename}`;
  const { error } = await supabase.storage.from(BUCKET).upload(path, bytes, { contentType: "application/pdf", upsert: false });
  if (error) return { error: error.message };
  const { data: older } = await supabase.storage.from(BUCKET).list(folder, { limit: 100 });
  const stale = (older ?? []).map((f) => `${folder}/${f.name}`).filter((p) => p !== path);
  if (stale.length) await supabase.storage.from(BUCKET).remove(stale);
  return { path };
}

/** The current saved packet for the invoice, if one was generated. */
export async function latestCarrierPacket(supabase: Supabase, orgId: string, invoiceId: string): Promise<{ path: string; generatedAt: string | null } | null> {
  const folder = packetFolder(orgId, invoiceId);
  const { data } = await supabase.storage.from(BUCKET).list(folder, { limit: 100, sortBy: { column: "created_at", order: "desc" } });
  const file = (data ?? []).find((f) => f.name.endsWith(".pdf"));
  if (!file) return null;
  const stamp = Number(file.name.split("-")[0]);
  return { path: `${folder}/${file.name}`, generatedAt: file.created_at ?? (Number.isFinite(stamp) ? new Date(stamp).toISOString() : null) };
}

export async function signedPacketUrl(supabase: Supabase, path: string, download: boolean): Promise<string | null> {
  const name = path.split("/").pop()!.replace(/^\d+-/, "");
  const { data } = await supabase.storage.from(BUCKET).createSignedUrl(path, 300, download ? { download: name } : undefined);
  return data?.signedUrl ?? null;
}
