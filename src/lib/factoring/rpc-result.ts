// Phase 3B.1.3 (Section D) -- structured RPC-result handling, extracted
// into its own framework-independent module (no "server-only"/Supabase
// import) so it can be unit-tested directly under `node --test` rather
// than only via source-text assertion.
//
// 0138/0139's protected RPCs (set_default_factoring_relationship,
// set_carrier_factoring_policy) return a NORMAL (non-exception) jsonb
// result for business-rule rejections -- {success:false, ...} -- so a
// caller that only checks the Postgres/transport-level `error` and never
// looks at `data` will silently treat a rejected change as if it
// succeeded. This module is the ONE place that decides "did this RPC
// actually succeed" -- it is never sufficient to check `error` alone, and
// success is NEVER inferred merely because `error` came back null.

export type StructuredRpcResult = {
  success?: boolean;
  message?: string;
  incomplete?: boolean;
  expected_version_required?: boolean;
  stale_record?: boolean;
  not_ready?: boolean;
  blocked?: boolean;
  reason?: string;
  no_op?: boolean;
  [key: string]: unknown;
};

export function mapStructuredRpcFailure(data: StructuredRpcResult | null | undefined): string {
  if (!data) return "This action could not be completed.";
  // The RPC's own `message` is already the human-readable sentence for
  // every rejection branch it can take (0138/0139's own text) -- prefer
  // it whenever present. The flag-only fallbacks below exist purely as a
  // defense-in-depth backstop in case a future branch of either RPC ever
  // omits `message`, so this mapping can never silently show "undefined."
  if (typeof data.message === "string" && data.message.trim()) return data.message;
  if (data.expected_version_required) return "This action requires the current version of the record you loaded. Please refresh the page and try again.";
  if (data.stale_record) return "This record was changed by someone else since you loaded it. Please refresh the page and try again.";
  if (data.incomplete) return "This factoring relationship is missing required configuration and cannot be used yet.";
  if (data.not_ready) return "This carrier is not ready for this change yet.";
  if (data.blocked) return "This change is currently blocked.";
  return "This action could not be completed.";
}

// Decides success/failure from a (data, error) pair EXACTLY the way a
// Supabase `.rpc()` call resolves it -- a pure function so both the real
// server action and this module's own tests exercise identical logic.
// `error` is transport/Postgres-exception level (a raised `raise
// exception`, e.g. FPAUT/FPROL/SFDNF/...); `data` is the RPC's own
// structured jsonb return value.
export function resolveStructuredRpcResult<T extends StructuredRpcResult>(
  data: T | null | undefined,
  error: { message: string } | null | undefined
): { ok: true; data: T } | { ok: false; error: string } {
  if (error) return { ok: false, error: error.message };
  if (!data || data.success !== true) return { ok: false, error: mapStructuredRpcFailure(data) };
  return { ok: true, data };
}
