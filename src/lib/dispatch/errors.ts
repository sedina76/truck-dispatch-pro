// Expected-vs-unexpected error architecture for the Dispatch create/update
// forms. Business conflicts (driver/truck/trailer already on an active
// dispatch, out-of-service equipment, a cross-carrier mismatch the DB
// guard rejects) are normal application feedback -- never a thrown
// exception that reaches the Next.js route error boundary. Genuinely
// unexpected errors (DB connectivity, a real bug) are logged in full
// server-side and shown to the user as one generic, detail-free message.

export type DispatchConflictField = "driver" | "truck" | "trailer" | null;

export type DispatchActionState = {
  error: string | null;
  code?: string;
  field?: DispatchConflictField;
  conflictDispatchId?: string | null;
  conflictLoadNumber?: string | null;
  maintenanceId?: string | null;
  /**
   * Echo of exactly what the user just submitted (spec section 7/9/10:
   * "Preserve all user-entered form values after the failed save"). A
   * server-action submission re-renders this route's Server Component
   * tree, which remounts the (otherwise uncontrolled) assignment fields --
   * so rather than fight that, DispatchForm feeds this echo back in as
   * each field's fresh defaultValue on that remount, instead of the
   * page's original load-time default.
   */
  values?: {
    carrierId: string;
    driverId: string;
    truckId: string;
    trailerId: string;
    feePercentage: string;
    notes: string;
    // Phase 3A.3 (item 1): echoed back so a failed reassignment resubmission
    // doesn't lose whatever reason the dispatcher already typed.
    reassignmentReason: string;
  };
};

export const DISPATCH_ACTION_INITIAL_STATE: DispatchActionState = { error: null };

// Thrown by checkAssignmentConflicts()/checkEquipmentAvailable() (and, for
// the concurrency backstop, re-derived in actions.ts after a 0054 unique-
// index rejection) -- the ONE type of throw these actions ever produce on
// purpose. Anything else escaping the try/catch is treated as a genuine
// bug, not a business conflict.
export class DispatchConflictError extends Error {
  code: string;
  field: DispatchConflictField;
  conflictDispatchId: string | null;
  conflictLoadNumber: string | null;
  maintenanceId: string | null;

  constructor(
    message: string,
    opts: {
      code: string;
      field?: DispatchConflictField;
      conflictDispatchId?: string | null;
      conflictLoadNumber?: string | null;
      maintenanceId?: string | null;
    }
  ) {
    super(message);
    this.name = "DispatchConflictError";
    this.code = opts.code;
    this.field = opts.field ?? null;
    this.conflictDispatchId = opts.conflictDispatchId ?? null;
    this.conflictLoadNumber = opts.conflictLoadNumber ?? null;
    this.maintenanceId = opts.maintenanceId ?? null;
  }
}

// guard_dispatch_org() (0048) messages -- already human-readable and free
// of any other org's data (only ever "must belong to..."/"does not belong
// to..."), but normalized to one consistent message + stable code rather
// than shown verbatim, so a DB-trigger wording change can never leak
// through as raw trigger text.
const GUARD_ORG_PATTERNS = [
  /must belong to the same organization/i,
  /does not belong to the selected carrier/i,
  /belongs to a different carrier/i,
];

type PgLikeError = { code?: string; message?: string };

function isPgLikeError(err: unknown): err is PgLikeError {
  return typeof err === "object" && err !== null && ("code" in err || "message" in err);
}

// The one place that decides "is this an expected business conflict the
// user should see as normal feedback, or a genuine bug." Every code path
// in createDispatch/updateDispatch funnels its catch block through this.
export function translateDispatchError(err: unknown): DispatchActionState {
  if (err instanceof DispatchConflictError) {
    return {
      error: err.message,
      code: err.code,
      field: err.field,
      conflictDispatchId: err.conflictDispatchId,
      conflictLoadNumber: err.conflictLoadNumber,
      maintenanceId: err.maintenanceId,
    };
  }

  if (isPgLikeError(err)) {
    // Postgres unique_violation on one of the 0054 concurrency-backstop
    // indexes should always have already been re-derived into a
    // DispatchConflictError by actions.ts before reaching here (so it hits
    // the branch above with the rich driver/truck/trailer + load-number
    // message). This is the fallback only if that re-derivation itself
    // came up empty -- still an expected "someone else just took this"
    // conflict, never a raw "duplicate key value violates..." string.
    if (err.code === "23505") {
      return { error: "This assignment was just taken by another dispatch. Please review and choose different equipment/driver.", code: "CONCURRENT_UPDATE" };
    }
    // Phase 3A.3 (item 2): a lock-wait timeout, a serialization failure, or
    // a genuine deadlock (all raw Postgres codes, never one of reassign_
    // dispatch_resources's own RRxxx codes) means this dispatch's row was
    // busy under another in-flight request the instant this one tried to
    // lock it -- "please retry" is the correct, honest answer (nothing was
    // corrupted, nothing was silently dropped), never a raw "canceling
    // statement due to statement timeout" or "deadlock detected" string.
    if (err.code === "55P03" || err.code === "57014" || err.code === "40P01" || err.code === "40001") {
      return {
        error: "This dispatch is currently being updated by another request. Please wait a moment and try again.",
        code: "LOCK_TIMEOUT",
      };
    }
    if (err.message && GUARD_ORG_PATTERNS.some((re) => re.test(err.message!))) {
      return { error: "This driver, truck, or trailer isn't valid for the selected carrier. Choose a driver/truck/trailer that belongs to the same carrier.", code: "CARRIER_MISMATCH" };
    }
  }

  // Plain validation errors from dispatchValues()/the load-id check --
  // expected, just not a "conflict" -- shown the same inline way, never as
  // a crash.
  if (err instanceof Error && /is required\.$|^Select a load first\.$/.test(err.message)) {
    return { error: err.message, code: "VALIDATION_ERROR" };
  }

  // Genuinely unexpected: log full detail server-side (stack trace, raw DB
  // error, whatever it is), tell the user nothing but the fact that it
  // failed. Never guessed into a false "business conflict."
  console.error("[dispatch] unexpected error saving dispatch:", err);
  return { error: "Unable to save this dispatch. Please try again.", code: "UNKNOWN" };
}
