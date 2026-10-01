// Cancel-dispatch helpers (Blocker F1). Pure -- no DB, no network.
//
// The Cancel action goes through public.transition_dispatch_status(..., 'cancelled', reason, key)
// (0134, SECURITY DEFINER): since 0135 revoked direct UPDATE on public.dispatches from
// `authenticated`, the SECURITY INVOKER public.cancel_dispatch() can no longer be called directly.
// transition_dispatch_status() delegates to it with its own privileges and remains the sole
// authority on role, organization, status and locking.

type RpcErrorLike = { code?: string | null } | null | undefined;

const CANCEL_ERROR_MESSAGES: Record<string, string> = {
  TSAUT: "You must be signed in to cancel a dispatch.",
  TDAUT: "You must be signed in to cancel a dispatch.",
  TSROL: "Only an owner, admin, or dispatcher can cancel a dispatch.",
  TDROL: "Only an owner, admin, or dispatcher can cancel a dispatch.",
  TSDNF: "That dispatch could not be found.",
  TDCNF: "That dispatch could not be found.",
  TDTRM: "A delivered or completed dispatch cannot be cancelled.",
  TSINV: "This dispatch cannot be cancelled in its current status.",
};

export const CANCEL_FALLBACK_MESSAGE = "Could not cancel this dispatch. Please try again.";

/** A fixed, user-safe message for a cancel failure. Never echoes the database's own message text
 *  (function names, uuids, SQLSTATE detail): unknown codes get the generic fallback. */
export function cancelDispatchErrorMessage(err: RpcErrorLike): string {
  const code = typeof err?.code === "string" ? err.code : "";
  return CANCEL_ERROR_MESSAGES[code] ?? CANCEL_FALLBACK_MESSAGE;
}

const IDEMPOTENCY_KEY_PATTERN = /^[A-Za-z0-9_-]{16,64}$/;

/** The per-submission idempotency key posted by the Cancel form. Returns null when absent/malformed
 *  (the RPC then runs without a ledger entry; it is still safe to repeat, because cancelling an
 *  already-cancelled dispatch is a no-op). */
export function cancelIdempotencyKey(raw: FormDataEntryValue | null): string | null {
  return typeof raw === "string" && IDEMPOTENCY_KEY_PATTERN.test(raw) ? raw : null;
}
