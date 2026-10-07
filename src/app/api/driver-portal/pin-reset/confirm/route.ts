import { NextRequest, NextResponse } from "next/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { createDriverPortalSession } from "@/lib/driver-portal/session";

// Driver Portal "Forgot PIN", step 2: emailed code + new PIN. On success
// driver_portal_finish_pin_reset (0172) has already set the PIN, cleared any
// lockout and ended every other session, so the driver is signed in here.
const ERRORS: Record<string, { message: string; status: number }> = {
  invalid_code: { message: "That code is not right. Check the email and try again.", status: 400 },
  code_expired: { message: "That code has expired. Request a new one.", status: 400 },
  too_many_attempts: { message: "Too many wrong codes. Request a new one.", status: 429 },
  invalid_pin: { message: "Your new PIN must be 4 to 6 digits.", status: 400 },
};

export async function POST(request: NextRequest) {
  const body = await request.json().catch(() => null);
  const phone = typeof body?.phone === "string" ? body.phone.trim() : "";
  const code = typeof body?.code === "string" ? body.code.replace(/\D/g, "") : "";
  const pin = typeof body?.pin === "string" ? body.pin.trim() : "";
  const confirm = typeof body?.confirm === "string" ? body.confirm.trim() : "";

  if (!phone || code.length !== 6) return NextResponse.json({ error: "Enter your phone number and the 6-digit code." }, { status: 400 });
  if (!/^[0-9]{4,6}$/.test(pin)) return NextResponse.json({ error: ERRORS.invalid_pin.message }, { status: 400 });
  if (pin !== confirm) return NextResponse.json({ error: "The two PINs don't match." }, { status: 400 });

  const supabase = createServiceRoleClient();
  const { data, error } = await supabase.rpc("driver_portal_finish_pin_reset", { p_phone: phone, p_code: code, p_new_pin: pin });
  if (error) {
    console.error("[pin-reset] finish failed:", error.message);
    return NextResponse.json({ error: "Could not reset your PIN. Try again." }, { status: 500 });
  }

  // The function RETURNS its error code (instead of raising) so a wrong
  // code's attempt is saved toward the 5-try limit.
  const row = (Array.isArray(data) ? data[0] : data) as { driver_id: string | null; organization_id: string | null; error: string | null } | undefined;
  if (!row || row.error || !row.driver_id || !row.organization_id) {
    const e = ERRORS[row?.error ?? "invalid_code"] ?? ERRORS.invalid_code;
    return NextResponse.json({ error: e.message }, { status: e.status });
  }

  await createDriverPortalSession(row.driver_id, row.organization_id, request.headers.get("user-agent"));
  return NextResponse.json({ ok: true });
}
