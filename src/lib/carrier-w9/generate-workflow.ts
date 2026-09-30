import "server-only";
import { createHash } from "node:crypto";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { renderCarrierW9Pdf } from "./pdf";
import { W9_BUCKET, MAX_GENERATED_BYTES, w9StoragePath, type CarrierW9Row } from "./types";

// Shared core of the certify -> render -> upload -> finalize workflow
// (2N.2 sections 15-18), callable from BOTH the staff-side server action
// and the carrier-onboarding-portal server action -- mirrors Broker
// Packet's generateBrokerPacket() shape (2M.3) exactly: certification
// already happened (via certify_carrier_w9(), called by the caller before
// this), this function renders from the now-frozen row, uploads to the
// deterministic path, and calls finalize_carrier_w9(). On any failure
// past that point it calls fail_carrier_w9() with a safe, bounded reason
// and best-effort removes a just-uploaded (never-finalized) object,
// never an already-finalized/historical one.
export type GenerateResult = { ok: true } | { ok: false; error: string };

type GenerationStage = "read" | "render" | "upload" | "finalize";

const FAILURE_REASON: Record<GenerationStage, string> = {
  read: "W-9 generation failed while reading the certified record.",
  render: "W-9 generation failed during PDF composition.",
  upload: "W-9 generation failed during secure storage.",
  finalize: "W-9 generation failed during database finalization.",
};

export async function runCarrierW9Generation(w9Id: string, organizationId: string, plaintextTin: string): Promise<GenerateResult> {
  const service = createServiceRoleClient();
  let storagePath: string | null = null;
  let stage: GenerationStage = "read";
  let databaseCode: string | null = null;
  try {
    const { data, error } = await service.from("carrier_w9s").select("*").eq("id", w9Id).eq("organization_id", organizationId).single();
    if (error || !data) {
      databaseCode = error?.code ?? null;
      throw new Error("Certified W-9 record could not be read.");
    }
    const w9 = data as unknown as CarrierW9Row;
    if (w9.status !== "draft" || !w9.certified_at) throw new Error("W-9 is not in a certified, awaiting-generation state.");

    stage = "render";
    const generated = await renderCarrierW9Pdf(w9, plaintextTin, new Date(w9.certified_at));
    if (generated.bytes.length > MAX_GENERATED_BYTES) throw new Error("The generated W-9 PDF exceeds the 50 MB limit.");
    const hash = createHash("sha256").update(generated.bytes).digest("hex");
    storagePath = w9StoragePath(w9);

    stage = "upload";
    const { error: uploadError } = await service.storage.from(W9_BUCKET).upload(storagePath, generated.bytes, { contentType: "application/pdf", upsert: false });
    if (uploadError) throw new Error("The generated W-9 could not be uploaded to secure storage.");

    stage = "finalize";
    const { error: finalizeError } = await service.rpc("finalize_carrier_w9", {
      p_w9_id: w9Id, p_storage_path: storagePath, p_file_size_bytes: generated.bytes.length,
      p_page_count: generated.pageCount, p_generated_pdf_sha256: hash,
    });
    if (finalizeError) {
      databaseCode = finalizeError.code ?? null;
      throw new Error("The generated W-9 could not be finalized.");
    }
    return { ok: true };
  } catch (error) {
    const message = error instanceof Error ? error.message : "W-9 generation failed.";
    // Never log the exception or PDF input: either may contain taxpayer data.
    // Stage and a PostgreSQL error code are enough to route the investigation.
    console.error("[carrier-w9] generation failed", {
      stage,
      databaseCode: databaseCode && /^[A-Za-z0-9]{5}$/.test(databaseCode) ? databaseCode : null,
    });
    if (storagePath) await service.storage.from(W9_BUCKET).remove([storagePath]);
    await service.rpc("fail_carrier_w9", { p_w9_id: w9Id, p_failure_reason: FAILURE_REASON[stage] });
    return { ok: false, error: message };
  }
}
