import "server-only";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentOrgId } from "@/lib/actions/records";

// ============================================================================
// The ONE place that turns "an incoming request" into a trusted, server-
// verified sending context (spec review item 2, Option B). Every caller of
// send-pipeline.ts's sendTenantEmail() must obtain this FIRST -- the
// pipeline itself refuses to accept a raw organizationId string, only this
// branded context object, which can only be constructed by actually
// re-deriving it from the CURRENT authenticated session right here.
//
// Required invariant (spec): authenticated actor -> authorized
// organization -> owned business entity -> valid tenant sender -> send.
// This module proves the first two links; verifyEntityOwnership() below
// (called from inside sendTenantEmail itself, not left to each caller)
// proves the third; resolveEmailSender() proves the fourth.
// ============================================================================

const BRAND = Symbol("EmailAuthorizationContext");

export type EmailAuthorizationContext = {
  readonly organizationId: string;
  readonly actorUserId: string;
  readonly [BRAND]: true;
};

export type ResolveAuthResult = { ok: true; context: EmailAuthorizationContext } | { ok: false; error: string };

/**
 * Re-derives organizationId/actorUserId from the CURRENT request's
 * authenticated Supabase session -- never from a parameter, never from
 * anything a client could influence. Call this once per request/action,
 * as early as possible, and thread the resulting context through to
 * sendTenantEmail(). A manipulated organizationId elsewhere in a request
 * body simply has no bearing on what this function returns.
 */
export async function resolveEmailAuthorizationContext(): Promise<ResolveAuthResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not authenticated." };

  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return { ok: false, error: "No organization on this account." };
  }

  return { ok: true, context: { organizationId, actorUserId: user.id, [BRAND]: true } };
}

export type OwnedEntityIds = {
  loadId?: string | null;
  invoiceId?: string | null;
  customerId?: string | null;
  brokerId?: string | null;
  dispatchId?: string | null;
  driverId?: string | null;
  carrierSetupPackageId?: string | null;
};

const ENTITY_TABLE: Record<keyof OwnedEntityIds, string> = {
  loadId: "loads",
  invoiceId: "invoices",
  customerId: "customers",
  brokerId: "brokers",
  dispatchId: "dispatches",
  driverId: "drivers",
  carrierSetupPackageId: "carrier_setup_packages",
};

/**
 * Independently re-verifies that every non-null entity id in `ids`
 * actually belongs to `organizationId` -- called from INSIDE
 * sendTenantEmail() itself (spec review item 2: "sendTenantEmail must not
 * trust arbitrary caller-supplied ... invoiceId/loadId/customerId/
 * brokerId/dispatchId/driverId"), not left as an assumption that every
 * caller already did this correctly. A service-role client is used
 * specifically so this check is authoritative regardless of the caller's
 * own RLS context -- it filters explicitly by organization_id itself,
 * which is the actual security boundary, not RLS convenience.
 *
 * Returns the subset of ids that are safe to write, and a list of any
 * that failed ownership verification (which sendTenantEmail treats as a
 * hard error, not a silent drop -- a mismatched id indicates something is
 * wrong upstream and should never be quietly ignored).
 */
export async function verifyEntityOwnership(organizationId: string, ids: OwnedEntityIds): Promise<{ ok: true; verified: OwnedEntityIds } | { ok: false; error: string }> {
  const service = createServiceRoleClient();
  const verified: OwnedEntityIds = {};

  for (const key of Object.keys(ENTITY_TABLE) as (keyof OwnedEntityIds)[]) {
    const id = ids[key];
    if (!id) continue;
    const { data } = await service.from(ENTITY_TABLE[key]).select("id").eq("id", id).eq("organization_id", organizationId).maybeSingle();
    if (!data) {
      return { ok: false, error: `The referenced ${key.replace("Id", "")} does not belong to this organization.` };
    }
    verified[key] = id;
  }

  return { ok: true, verified };
}
