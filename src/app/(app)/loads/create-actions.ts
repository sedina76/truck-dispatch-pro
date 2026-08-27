"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";
import { uploadLoadDocument } from "./pod-actions";
import { zonedDateTimeToUtc, validateWindowOrder } from "@/lib/timezone/convert";
import { isValidIanaTimezone } from "@/lib/timezone/iana";

// New Load: books the load AND its pickup/delivery/additional stops in one
// atomic call to create_load_with_stops() (0047_new_load_workflow.sql) --
// a plain (non-security-definer) Postgres function, so both inserts run
// under the caller's own RLS exactly as if done separately, but as one
// function invocation Postgres can never partially commit (spec section
// 14: never a load with no stops, or vice versa).

type StopInput = {
  stop_type: "pickup" | "delivery";
  stop_sequence: number;
  facility_name: string | null;
  address_line1: string | null;
  address_line2: string | null;
  city: string;
  state: string;
  postal_code: string | null;
  contact_name: string | null;
  contact_phone: string | null;
  scheduled_at: string | null;
  scheduled_window_end: string | null;
  reference_number: string | null;
  notes: string | null;
  timezone: string | null;
  timezone_source: "manual" | "organization_default" | null;
};

// ---------------------------------------------------------------------------
// Phase 2C.1 fix: this used to be combineDateTime(), which built
// `new Date(\`${date}T${time}:00\`)` -- parsed in the SERVER PROCESS's own
// local timezone, not the stop's location, not even this org's own
// configured organizations.timezone. "3:00 PM" for a Memphis pickup landed
// on whatever instant 3:00 PM happened to be whereever the server was
// actually running -- silently wrong by a full UTC-offset's worth of
// minutes for any stop outside that one zone. Replaced with the real,
// DST-aware, timezone-explicit conversion (src/lib/timezone/convert.ts),
// verified server-timezone-independent by a live TZ=UTC vs
// TZ=America/Los_Angeles test producing identical output before this was
// trusted. Throws (not returns null) on an unparseable/nonexistent time so
// a bad stop appointment can never silently become "no time at all"
// instead of a value the dispatcher actually entered.
function combineDateTimeInZone(date: string, time: string, timezone: string, fieldLabel: string): string | null {
  if (!date) return null;
  const result = zonedDateTimeToUtc(date, time || "00:00", timezone);
  if (!result.ok) throw new Error(`${fieldLabel}: ${result.error}`);
  return result.iso;
}

// Canonical, timezone-parsing-free comparison key for "is X before Y"
// checks (spec: pickup-vs-delivery ordering). Deliberately NEVER runs a
// date-only string through `new Date(...)` -- that form is parsed as UTC
// midnight per the JS spec, while a date+time string with no offset (as
// combineDateTime above builds) is parsed as LOCAL time. Comparing those
// two constructions against each other silently shifts the calendar day
// by the server's UTC offset (this app's dev box is America/Los_Angeles,
// UTC-7/8 -- enough to flip which side of midnight a date-only string
// lands on). This function sidesteps the whole issue: it never
// instantiates a Date object at all, just validates the two raw form
// strings with a regex and concatenates them into one zero-padded
// "YYYY-MM-DDTHH:MM" string per side. Two such strings compare correctly
// with plain `<`/`>` string comparison -- lexicographic order IS
// chronological order for same-format, zero-padded ISO-style strings,
// with no timezone interpretation involved anywhere. A blank time is
// treated as "00:00" on both sides, so two same-day stops with no time
// entered compare as equal (neither before the other) rather than one
// arbitrarily "winning."
function localDateTimeKey(date: string, time: string): string {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error(`Invalid date: "${date}"`);
  const safeTime = /^\d{2}:\d{2}$/.test(time) ? time : "00:00";
  return `${date}T${safeTime}`;
}

// Parses the AdditionalStopsFields component's `extra_stops[key][field]`
// naming into one record per stop, preserving submission order (the order
// stops were added -- see that component for the sequencing rationale).
function parseExtraStops(formData: FormData): Record<string, string>[] {
  const map = new Map<string, Record<string, string>>();
  for (const [key, value] of formData.entries()) {
    const m = key.match(/^extra_stops\[([^\]]+)\]\[([^\]]+)\]$/);
    if (!m) continue;
    const [, stopKey, field] = m;
    if (!map.has(stopKey)) map.set(stopKey, {});
    map.get(stopKey)![field] = String(value);
  }
  return Array.from(map.values());
}

export async function createLoadWithStops(formData: FormData) {
  const supabase = await createClient();

  // ---- Validation (spec section 15) --------------------------------------
  // Load number is no longer read from the form at all (0114: automatic
  // organization-scoped load-number generation) -- it is allocated
  // server-side, inside create_load_with_stops() itself, by
  // allocate_load_number(), which derives the organization exclusively
  // from the caller's own authenticated session. A client-supplied
  // "load_number" field, if a stale request still sent one, is never
  // looked at anywhere in this function.
  const brokerId = emptyToNull(formData.get("broker_id"));
  const customerId = emptyToNull(formData.get("customer_id"));
  if (!brokerId && !customerId) throw new Error("Select a broker (brokered load) or a customer (direct load).");

  // Default timezone (spec section 11): stop-derived if the dispatcher
  // picked one, otherwise this organization's own configured timezone --
  // NEVER the dispatcher's browser timezone (they may be booking a New
  // York appointment from a San Diego office).
  let orgId: string;
  try {
    orgId = await getCurrentOrgId();
  } catch {
    throw new Error("No organization on this account.");
  }
  const { data: org } = await supabase.from("organizations").select("timezone").eq("id", orgId).maybeSingle();
  const orgTimezone = org?.timezone && isValidIanaTimezone(org.timezone) ? org.timezone : "UTC";

  function resolveFormTimezone(fieldName: string): { timezone: string; source: "manual" | "organization_default" } {
    const picked = String(formData.get(fieldName) || "").trim();
    if (picked && isValidIanaTimezone(picked)) return { timezone: picked, source: "manual" };
    return { timezone: orgTimezone, source: "organization_default" };
  }

  const pickupCity = String(formData.get("pickup_city") || "").trim();
  const pickupState = String(formData.get("pickup_state") || "").trim();
  const pickupDate = String(formData.get("pickup_date") || "").trim();
  const pickupTime = String(formData.get("pickup_time") || "").trim();
  if (!pickupCity || !pickupState) throw new Error("Pickup city and state are required.");
  if (!pickupDate) throw new Error("Pickup date is required.");
  const pickupTz = resolveFormTimezone("pickup_timezone");

  const deliveryCity = String(formData.get("delivery_city") || "").trim();
  const deliveryState = String(formData.get("delivery_state") || "").trim();
  const deliveryDate = String(formData.get("delivery_date") || "").trim();
  const deliveryTime = String(formData.get("delivery_time") || "").trim();
  if (!deliveryCity || !deliveryState) throw new Error("Delivery city and state are required.");
  if (!deliveryDate) throw new Error("Delivery date is required.");
  const deliveryTz = resolveFormTimezone("delivery_timezone");

  // Full date+time ordering (not date-only) -- a same-day delivery
  // scheduled EARLIER in the day than pickup is still invalid, and this
  // must never fabricate a rejection for a genuinely later delivery date/
  // time. See localDateTimeKey() above for why this is a plain string
  // comparison rather than two `new Date(...)` calls.
  if (localDateTimeKey(deliveryDate, deliveryTime) < localDateTimeKey(pickupDate, pickupTime)) {
    throw new Error("Delivery cannot be scheduled before pickup.");
  }

  const rate = toNumber(formData.get("rate"));
  if (rate === null || rate < 0) throw new Error("A valid rate is required.");

  // ---- Build the ordered stop list ---------------------------------------
  // Pickup -> additional stops (order added) -> Delivery. See
  // additional-stops-fields.tsx for why full drag-and-drop reordering
  // wasn't built in this pass (KNOWN LIMITATIONS in the final report).
  const stops: StopInput[] = [];
  let seq = 1;

  const pickupScheduledAt = combineDateTimeInZone(pickupDate, pickupTime, pickupTz.timezone, "Pickup appointment");
  const pickupWindowEnd = emptyToNull(formData.get("pickup_window_end"))
    ? combineDateTimeInZone(pickupDate, String(formData.get("pickup_window_end")), pickupTz.timezone, "Pickup appointment window end")
    : null;
  if (pickupScheduledAt) {
    const windowCheck = validateWindowOrder(pickupScheduledAt, pickupWindowEnd);
    if (!windowCheck.ok) throw new Error(`Pickup: ${windowCheck.error}`);
  }

  stops.push({
    stop_type: "pickup",
    stop_sequence: seq++,
    facility_name: emptyToNull(formData.get("pickup_facility_name")),
    address_line1: emptyToNull(formData.get("pickup_address_line1")),
    address_line2: emptyToNull(formData.get("pickup_address_line2")),
    city: pickupCity,
    state: pickupState,
    postal_code: emptyToNull(formData.get("pickup_postal_code")),
    contact_name: emptyToNull(formData.get("pickup_contact_name")),
    contact_phone: emptyToNull(formData.get("pickup_contact_phone")),
    scheduled_at: pickupScheduledAt,
    scheduled_window_end: pickupWindowEnd,
    reference_number: emptyToNull(formData.get("pickup_reference_number")),
    notes: emptyToNull(formData.get("pickup_notes")),
    timezone: pickupTz.timezone,
    timezone_source: pickupTz.source,
  });

  for (const fields of parseExtraStops(formData)) {
    const city = (fields.city || "").trim();
    const state = (fields.state || "").trim();
    const date = (fields.date || "").trim();
    if (!city || !state || !date) throw new Error("Every additional stop needs a city, state, and date.");
    const extraTz = fields.timezone && isValidIanaTimezone(fields.timezone) ? { timezone: fields.timezone, source: "manual" as const } : { timezone: orgTimezone, source: "organization_default" as const };
    stops.push({
      stop_type: fields.stop_type === "delivery" ? "delivery" : "pickup",
      stop_sequence: seq++,
      facility_name: fields.facility_name || null,
      address_line1: fields.address_line1 || null,
      address_line2: null,
      city,
      state,
      postal_code: fields.postal_code || null,
      contact_name: fields.contact_name || null,
      contact_phone: fields.contact_phone || null,
      scheduled_at: combineDateTimeInZone(date, fields.time || "", extraTz.timezone, `${fields.stop_type === "delivery" ? "Delivery" : "Pickup"} stop appointment`),
      scheduled_window_end: null,
      reference_number: fields.reference_number || null,
      notes: fields.notes || null,
      timezone: extraTz.timezone,
      timezone_source: extraTz.source,
    });
  }

  const deliveryScheduledAt = combineDateTimeInZone(deliveryDate, deliveryTime, deliveryTz.timezone, "Delivery appointment");
  const deliveryWindowEnd = emptyToNull(formData.get("delivery_window_end"))
    ? combineDateTimeInZone(deliveryDate, String(formData.get("delivery_window_end")), deliveryTz.timezone, "Delivery appointment window end")
    : null;
  if (deliveryScheduledAt) {
    const windowCheck = validateWindowOrder(deliveryScheduledAt, deliveryWindowEnd);
    if (!windowCheck.ok) throw new Error(`Delivery: ${windowCheck.error}`);
  }

  stops.push({
    stop_type: "delivery",
    stop_sequence: seq++,
    facility_name: emptyToNull(formData.get("delivery_facility_name")),
    address_line1: emptyToNull(formData.get("delivery_address_line1")),
    address_line2: emptyToNull(formData.get("delivery_address_line2")),
    city: deliveryCity,
    state: deliveryState,
    postal_code: emptyToNull(formData.get("delivery_postal_code")),
    contact_name: emptyToNull(formData.get("delivery_contact_name")),
    contact_phone: emptyToNull(formData.get("delivery_contact_phone")),
    scheduled_at: deliveryScheduledAt,
    scheduled_window_end: deliveryWindowEnd,
    reference_number: emptyToNull(formData.get("delivery_reference_number")),
    notes: emptyToNull(formData.get("delivery_notes")),
    timezone: deliveryTz.timezone,
    timezone_source: deliveryTz.source,
  });

  // ---- Atomic create (load + every stop, one function call) -------------
  const loadPayload = {
    broker_id: brokerId,
    customer_id: customerId,
    status: String(formData.get("status") || "draft"),
    commodity: emptyToNull(formData.get("commodity")),
    weight_lbs: toNumber(formData.get("weight_lbs")),
    equipment_type: emptyToNull(formData.get("equipment_type")),
    total_miles: toNumber(formData.get("total_miles")),
    rate,
    rate_confirmation_number: emptyToNull(formData.get("rate_confirmation_number")),
    special_instructions: emptyToNull(formData.get("special_instructions")),
  };

  const { data: loadId, error } = await supabase.rpc("create_load_with_stops", {
    p_load: loadPayload,
    p_stops: stops,
  });
  if (error) {
    // A 23505 here would mean the org-scoped unique index on
    // (organization_id, load_number) rejected the number
    // allocate_load_number() just generated -- effectively impossible
    // (that function is the only writer of the counter it reads from,
    // inside this same transaction), but the index remains as the final
    // backstop per spec section 6, so its error is still surfaced rather
    // than swallowed.
    if (error.code === "23505") throw new Error("Could not create this load: a load number conflict was detected. Please try again.");

    // DEPLOYMENT-ORDER MISMATCH (0114): this application code no longer
    // sends a "load_number" key in p_load at all (server-side allocation
    // replaced it), but if migration 0114 has not yet been applied, the
    // DATABASE is still running the pre-0114 create_load_with_stops()
    // body, which reads p_load->>'load_number' and inserts it directly --
    // that now evaluates to SQL NULL, which loads.load_number's NOT NULL
    // constraint rejects (23502) before any row is created. This is a
    // deployment-sequencing error, not a user-facing data problem, and the
    // real Postgres message ("null value in column \"load_number\"...")
    // would be both confusing and an internal-schema leak if shown as-is
    // -- redirect to a clean, actionable banner instead of throwing, so
    // this never reaches a thrown-error / Next.js error-overlay path.
    // Removable once 0114 is confirmed applied in every environment this
    // code runs against; the RPC calling convention itself does not
    // change when that happens; this branch simply stops being reachable.
    if (error.code === "23502" && error.message?.includes("load_number")) {
      redirect("/loads/new?load_numbering_inactive=1");
    }

    throw new Error(error.message);
  }

  // ---- Optional Rate Confirmation upload (spec section 10) ---------------
  // Reuses uploadLoadDocument verbatim -- the exact same staff-only upload
  // path Load Detail's "Billing Documents" section already uses. Attempted
  // AFTER the load+stops exist, so a failed upload never undoes the
  // (already-committed, atomic) load creation -- it just redirects with a
  // flag instead of throwing, so the dispatcher isn't told load creation
  // itself failed.
  const rateConFile = formData.get("rate_confirmation_file");
  if (rateConFile instanceof File && rateConFile.size > 0) {
    const uploadForm = new FormData();
    uploadForm.set("file", rateConFile);
    try {
      await uploadLoadDocument(loadId as string, "rate_confirmation", uploadForm);
    } catch {
      revalidatePath("/loads");
      redirect(`/loads/${loadId}?rate_con_upload_failed=1`);
    }
  }

  // ---- Display the generated number (spec section 10) --------------------
  // The detail page's own header already renders loadRow.load_number --
  // the ?created=1 flag just adds a one-time success banner calling it out
  // explicitly, since the dispatcher who just submitted this form never
  // typed or saw a load number themselves.
  revalidatePath("/loads");
  redirect(`/loads/${loadId}?created=1`);
}
