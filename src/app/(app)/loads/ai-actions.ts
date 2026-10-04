"use server";

import { createClient } from "@/lib/supabase/server";
import { checkOperationalAccess } from "@/lib/billing/operational-access";
import { readDocumentAsJson, documentBlock, AiNotConfiguredError } from "@/lib/ai/anthropic";
import { RATE_CON_PROMPT, RATE_CON_SCHEMA, normalizeExtraction, parseModelJson, matchBroker, type ExtractedLoad } from "@/lib/ai/rate-con";

// "Fill from rate confirmation" on New Load. Reads the uploaded PDF/photo
// with Claude and returns SUGGESTED values -- nothing is saved here; the
// dispatcher reviews the filled form and clicks Create Load as usual.
// Staff who can book loads only (owner/admin/dispatcher/accountant).

const MAX_BYTES = 15 * 1024 * 1024;
const TYPES = new Set(["application/pdf", "image/jpeg", "image/png"]);
const STAFF = new Set(["owner", "admin", "dispatcher", "accountant"]);

export type RateConReadResult =
  | { ok: true; load: ExtractedLoad; brokerId: string | null }
  | { ok: false; error: string; notConfigured?: boolean };

export async function readRateConfirmation(formData: FormData): Promise<RateConReadResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not signed in." };
  const { data: role } = await supabase.rpc("current_role");
  if (!STAFF.has(String(role ?? ""))) return { ok: false, error: "Only office staff can use this." };
  const access = await checkOperationalAccess();
  if (!access.ok) return { ok: false, error: "Your organization's subscription does not permit this action." };

  const file = formData.get("file");
  if (!(file instanceof File) || file.size === 0) return { ok: false, error: "Choose the rate confirmation (PDF, JPG or PNG)." };
  if (file.size > MAX_BYTES) return { ok: false, error: "File is too large (15 MB max)." };
  if (!TYPES.has(file.type)) return { ok: false, error: "Use a PDF, JPG or PNG." };

  let load: ExtractedLoad;
  try {
    const text = await readDocumentAsJson(documentBlock(await file.arrayBuffer(), file.type), RATE_CON_PROMPT, RATE_CON_SCHEMA);
    load = normalizeExtraction(parseModelJson(text));
  } catch (err) {
    if (err instanceof AiNotConfiguredError) {
      return { ok: false, notConfigured: true, error: "AI entry isn't set up yet: add ANTHROPIC_API_KEY in Vercel (Settings -> Environment Variables) and redeploy." };
    }
    return { ok: false, error: err instanceof Error ? err.message : "The document could not be read." };
  }
  if (load.stops.length === 0 && !load.rate_total && !load.broker_name) {
    return { ok: false, error: "Nothing load-related was found in that document. Is it a rate confirmation?" };
  }

  const { data: brokers } = await supabase.from("brokers").select("id, company_name, mc_number");
  const brokerId = matchBroker((brokers ?? []) as { id: string; company_name: string; mc_number: string | null }[], load.broker_name, load.broker_mc_number);
  return { ok: true, load, brokerId };
}
