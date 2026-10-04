import "server-only";

// Minimal Claude API call for "read this document and return JSON".
// Server-side only: the key (ANTHROPIC_API_KEY) never reaches the browser.
// The document goes first, then the instructions (Anthropic's guidance for
// PDFs). Structured output (output_config.format) is requested; if the API
// rejects that option, it retries with a plain "JSON only" request -- the
// answer is parsed and validated by our own code either way.

const API_URL = "https://api.anthropic.com/v1/messages";
const API_VERSION = "2023-06-01";
const TIMEOUT_MS = 55_000;

export class AiNotConfiguredError extends Error {}

export function aiConfigured(): boolean {
  return !!process.env.ANTHROPIC_API_KEY;
}

type DocBlock =
  | { type: "document"; source: { type: "base64"; media_type: "application/pdf"; data: string } }
  | { type: "image"; source: { type: "base64"; media_type: "image/jpeg" | "image/png"; data: string } };

export function documentBlock(bytes: ArrayBuffer, mimeType: string): DocBlock {
  const data = Buffer.from(bytes).toString("base64");
  if (mimeType === "application/pdf") return { type: "document", source: { type: "base64", media_type: "application/pdf", data } };
  if (mimeType === "image/jpeg" || mimeType === "image/png") return { type: "image", source: { type: "base64", media_type: mimeType, data } };
  throw new Error("Use a PDF, JPG or PNG.");
}

async function post(body: Record<string, unknown>): Promise<{ status: number; json: unknown }> {
  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) throw new AiNotConfiguredError("AI entry isn't set up yet.");
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(API_URL, {
      method: "POST",
      headers: { "content-type": "application/json", "x-api-key": key, "anthropic-version": API_VERSION },
      body: JSON.stringify(body),
      signal: ctrl.signal,
      cache: "no-store",
    });
    return { status: res.status, json: await res.json().catch(() => null) };
  } finally {
    clearTimeout(timer);
  }
}

function textOf(json: unknown): string {
  const content = (json as { content?: { type: string; text?: string }[] } | null)?.content ?? [];
  return content.filter((b) => b.type === "text" && typeof b.text === "string").map((b) => b.text).join("");
}

/** Send one document + instructions; return the model's text answer (expected to be JSON). */
export async function readDocumentAsJson(doc: DocBlock, prompt: string, schema: Record<string, unknown>): Promise<string> {
  const model = process.env.ANTHROPIC_MODEL || "claude-sonnet-5-5";
  const base = {
    model,
    max_tokens: 4096,
    messages: [{ role: "user", content: [doc, { type: "text", text: prompt }] }],
  };
  const attempts: Record<string, unknown>[] = [
    { ...base, output_config: { format: { type: "json_schema", schema } } },
    { ...base, output_config: { format: { type: "json", schema } } },
    { ...base, messages: [{ role: "user", content: [doc, { type: "text", text: `${prompt}\n\nReply with ONLY a JSON object matching this JSON Schema:\n${JSON.stringify(schema)}` }] }] },
  ];
  let last = "";
  for (const body of attempts) {
    let r: { status: number; json: unknown };
    try {
      r = await post(body);
    } catch (err) {
      if (err instanceof AiNotConfiguredError) throw err;
      throw new Error("The AI service didn't answer in time. Try again, or fill the form by hand.");
    }
    if (r.status === 200) {
      const text = textOf(r.json);
      if (text) return text;
      last = "empty answer";
      continue;
    }
    const msg = (r.json as { error?: { message?: string } } | null)?.error?.message ?? `HTTP ${r.status}`;
    console.warn("[ai] Claude request failed:", r.status, msg);
    if (r.status === 400) {
      last = msg;
      continue; // an option this model doesn't accept -- try the simpler request
    }
    if (r.status === 401 || r.status === 403) throw new Error("The AI key was rejected. Check ANTHROPIC_API_KEY.");
    if (r.status === 429 || r.status === 529) throw new Error("The AI service is busy. Try again in a minute.");
    throw new Error("The AI service had a problem. Try again, or fill the form by hand.");
  }
  console.warn("[ai] all request shapes rejected:", last);
  throw new Error("The document could not be read. Try a clearer PDF, or fill the form by hand.");
}
