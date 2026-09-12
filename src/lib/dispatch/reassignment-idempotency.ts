import "server-only";
import { createHash } from "node:crypto";

// Phase 3A.4 (item 4): the idempotency key public.reassign_dispatch_
// resources() (0135) uses is generated ENTIRELY server-side, derived from
// the semantic content of the request -- never a browser-supplied token
// (a client could otherwise submit an arbitrary key, defeating the whole
// point of the ledger's dedup guarantee).
//
// The key is a deterministic hash of exactly the fields that define "is
// this the SAME logical reassignment": which dispatch, which driver/
// truck/trailer are being requested, the reason text, and the version
// (expected_updated_at) the caller believes it is applying against --
// scoped by organization and by this specific operation name so it can
// never collide with, or be confused for, a key from any other RPC or a
// future incompatible revision of this scheme. JSON.stringify on the
// ordered array of fields (rather than delimiter-joined string
// concatenation) is what actually makes the hash input unambiguous: it
// escapes each field's own content, so no combination of field VALUES can
// ever be re-sliced into a different combination of field BOUNDARIES.
//
// This gives exactly the properties Phase 3A.4 (item 4) requires, with NO
// server-side session/state to manage at all:
//   * "Retries reuse the same request key where possible" -- a byte-
//     identical resubmission (a network hiccup, a double-click before the
//     Save button disables, an automatic client retry) of the SAME
//     logical change reduces to the IDENTICAL hash, every time, with
//     nothing to store or thread through the client -- the hidden
//     expected_updated_at field is the one piece of state that must
//     survive a failed submission for this to hold, and it already does:
//     updateDispatch() only redirects on success, so a failed attempt
//     re-renders this SAME mounted form with the SAME server-loaded
//     expected_updated_at value still in the DOM (see dispatch/[id]/
//     page.tsx's hidden field and DispatchForm's failure-path re-render).
//   * "Concurrent replay produces one mutation and one audit event" -- the
//     RPC's own ledger (dispatch_resource_reassignments, keyed on
//     (dispatch_id, idempotency_key)) recognizes the identical key and
//     replays the cached result -- proven under real concurrency by
//     TEST_CONCURRENCY_0135's Scenario 7.
//   * "A different legitimate edit receives a different key" -- changing
//     ANYTHING that matters (a different driver, a different reason, a
//     newer version after a legitimate prior save) changes the hash and
//     therefore the key, so it is never mistaken for a replay of
//     something else.
//   * "Keys remain organization- and operation-scoped" -- organization_id
//     and a fixed operation-name literal are folded into the hash input,
//     plus an "rr1:" prefix naming the operation/scheme version.
export function buildReassignmentIdempotencyKey(params: {
  organizationId: string;
  dispatchId: string;
  driverId: string;
  truckId: string;
  trailerId: string | null;
  reason: string | null;
  expectedUpdatedAt: string | null;
}): string {
  const hash = createHash("sha256");
  hash.update(
    JSON.stringify([
      "reassign_dispatch_resources",
      params.organizationId,
      params.dispatchId,
      params.driverId,
      params.truckId,
      params.trailerId ?? null,
      params.reason ?? null,
      params.expectedUpdatedAt ?? null,
    ])
  );
  return `rr1:${hash.digest("hex")}`;
}
