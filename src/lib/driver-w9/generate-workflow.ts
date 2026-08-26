import "server-only";
import { createHash } from "node:crypto";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { renderCarrierW9Pdf } from "@/lib/carrier-w9/pdf";
import { DRIVER_W9_BUCKET, MAX_GENERATED_BYTES, driverW9StoragePath, type DriverW9Row } from "./types";

// Phase 2Q.2B -- shared core of the certify -> render -> upload -> finalize
// workflow, mirroring src/lib/carrier-w9/generate-workflow.ts exactly
// (same reserve/render/upload/finalize shape, same fail-safely-on-any-
// error-past-upload behavior). Reuses renderCarrierW9Pdf() itself -- the
// one IRS Form W-9 filler in the codebase -- rather than a second copy.
export type GenerateResult = { ok: true } | { ok: false; error: string };

function safeFailureStage(message: string): string {
  if (/pdf|page|form|template/i.test(message)) return "W-9 generation failed during PDF composition.";
  if (/upload|storage/i.test(message)) return "W-9 generation failed during secure storage.";
  return "W-9 generation failed.";
}

export async function runDriverW9Generation(w9Id: string, organizationId: string, plaintextTin: string): Promise<GenerateResult> {
  const service = createServiceRoleClient();
  let storagePath: string | null = null;
  try {
    const { data, error } = await service.from("driver_w9s").select("*").eq("id", w9Id).eq("organization_id", organizationId).single();
    if (error || !data) throw new Error("Certified W-9 record could not be read.");
    const w9 = data as unknown as DriverW9Row;
    if (w9.status !== "draft" || !w9.certified_at) throw new Error("W-9 is not in a certified, awaiting-generation state.");

    const generated = await renderCarrierW9Pdf(w9, plaintextTin, new Date(w9.certified_at));
    if (generated.bytes.length > MAX_GENERATED_BYTES) throw new Error("The generated W-9 PDF exceeds the 5 MB limit.");
    const hash = createHash("sha256").update(generated.bytes).digest("hex");
    storagePath = driverW9StoragePath(w9);

    const { error: uploadError } = await service.storage.from(DRIVER_W9_BUCKET).upload(storagePath, generated.bytes, { contentType: "application/pdf", upsert: false });
    if (uploadError) throw new Error("The generated W-9 could not be uploaded to secure storage.");

    const { error: finalizeError } = await service.rpc("finalize_driver_w9", {
      p_w9_id: w9Id, p_storage_path: storagePath, p_file_size_bytes: generated.bytes.length,
      p_page_count: generated.pageCount, p_generated_pdf_sha256: hash,
    });
    if (finalizeError) throw new Error("The generated W-9 could not be finalized.");
    return { ok: true };
  } catch (error) {
    const message = error instanceof Error ? error.message : "W-9 generation failed.";
    if (storagePath) await service.storage.from(DRIVER_W9_BUCKET).remove([storagePath]);
    await service.rpc("fail_driver_w9", { p_w9_id: w9Id, p_failure_reason: safeFailureStage(message) });
    return { ok: false, error: message };
  }
}
