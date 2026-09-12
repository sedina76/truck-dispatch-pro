"use server";

import { insertRecord, updateRecord } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";

// Fields an ordinary authenticated user (owner/admin/dispatcher) may set on
// an UPDATE, post-creation -- exactly migration 0134's column-privilege
// grant list (Phase 3A.1 hotfix, item A). carrier_id is deliberately
// EXCLUDED here (see updateTrailer below); ownership_scope was never
// editable via this form at all.
function editableTrailerValues(formData: FormData) {
  return {
    unit_number: String(formData.get("unit_number")),
    trailer_type: emptyToNull(formData.get("trailer_type")),
    length_ft: toNumber(formData.get("length_ft")),
    license_plate: emptyToNull(formData.get("license_plate")),
    license_state: emptyToNull(formData.get("license_state")),
    ownership_type: emptyToNull(formData.get("ownership_type")),
    status: String(formData.get("status") || "active"),
    registration_expiry_date: emptyToNull(formData.get("registration_expiry_date")),
    annual_inspection_expiry_date: emptyToNull(formData.get("annual_inspection_expiry_date")),
  };
}

export async function createTrailer(formData: FormData) {
  // carrier_id IS included on create only -- INSERT privilege was never
  // revoked (0132/0134 only narrow UPDATE), and an initial carrier
  // assignment at creation time is not a "change" in the sense correction
  // #7/0134 guards against (matches the same NULL -> value pattern already
  // established for loads.carrier_id, decision 1).
  await insertRecord(
    "trailers",
    { ...editableTrailerValues(formData), carrier_id: emptyToNull(formData.get("carrier_id")) },
    "/trailers"
  );
}

export async function updateTrailer(id: string, formData: FormData) {
  // carrier_id is DELIBERATELY excluded from every UPDATE payload (Phase
  // 3A.1 hotfix compatibility fix): migration 0134 revokes authenticated's
  // UPDATE privilege on trailers.carrier_id at the column level, and
  // Postgres checks column privileges against a statement's SET list, not
  // against whether the value actually changes -- naming carrier_id here
  // at all, even unchanged, would make EVERY ordinary trailer edit fail
  // with "permission denied for table trailers" (confirmed empirically,
  // TEST_0134_..., PART A3). Changing a trailer's carrier ownership after
  // creation now requires an owner/admin via
  // public.approve_trailer_ownership_scope() (no dedicated UI yet -- the
  // edit form's Carrier field is disabled, not removed, see
  // trailers/[id]/page.tsx).
  await updateRecord("trailers", id, editableTrailerValues(formData), "/trailers");
}
