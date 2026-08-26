"use server";

import { getDriverW9SignedUrlOrThrow, DriverW9ResourceNotFoundError } from "@/lib/driver-w9/signed-url";
import { createClient } from "@/lib/supabase/server";

// Phase 2Q.2B -- staff-side Driver W-9 actions. Mirrors
// src/app/(app)/carriers/onboarding/[id]/w9-actions.ts's own reveal RPC
// call, but returns the plain string|null shape
// src/components/ui/reveal-pii-button.tsx's onReveal contract expects
// (the same shared component driver_applications' own SSN reveal already
// uses) rather than an {ok,data} envelope -- throws on failure, exactly
// like revealApplicationSsn() in ../actions.ts.
export async function revealDriverW9Tin(w9Id: string, reason?: string): Promise<string | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reveal_driver_w9_tin", { p_w9_id: w9Id, p_reason: reason ?? null });
  if (error) throw new Error(error.message);
  return data as string | null;
}

export async function getDriverW9Url(w9Id: string, download: boolean): Promise<{ ok: true; url: string } | { ok: false; error: string }> {
  try {
    const result = await getDriverW9SignedUrlOrThrow(w9Id, download);
    return { ok: true, url: result.url };
  } catch (error) {
    if (error instanceof DriverW9ResourceNotFoundError) return { ok: false, error: "W-9 not found." };
    return { ok: false, error: "Could not open the W-9." };
  }
}
