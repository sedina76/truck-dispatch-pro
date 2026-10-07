import { NextRequest, NextResponse } from "next/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { sendTransactionalEmail, EMAIL_PROVIDER_CONFIGURED } from "@/lib/email/provider";
import { notifyOfficeOfPinResetRequest } from "@/lib/notify/office-notify";

// Driver Portal "Forgot PIN", step 1. The driver gives their phone number;
// if it has an active portal login, driver_portal_begin_pin_reset (0172)
// creates a one-time 6-digit code, which is emailed to the address on the
// driver's record, and the office is told either way.
//
// The response is IDENTICAL whether or not the number exists, has an email,
// or hit the 3-per-hour limit, so this endpoint can't be used to find out
// which phone numbers belong to drivers.
const GENERIC = {
  ok: true,
  message:
    "If that number has Driver Portal access, we emailed a 6-digit code to the email on your driver record and let your dispatch office know. No email? Your office can set a new PIN for you.",
};

export async function POST(request: NextRequest) {
  const body = await request.json().catch(() => null);
  const phone = typeof body?.phone === "string" ? body.phone.trim() : "";
  if (phone.replace(/\D/g, "").length < 7) {
    return NextResponse.json({ error: "Enter the phone number you use to sign in." }, { status: 400 });
  }

  const supabase = createServiceRoleClient();
  const { data, error } = await supabase.rpc("driver_portal_begin_pin_reset", { p_phone: phone });
  if (error) {
    console.error("[pin-reset] begin failed:", error.message);
    return NextResponse.json(GENERIC);
  }

  const row = (Array.isArray(data) ? data[0] : data) as
    | { driver_id: string; organization_id: string; first_name: string | null; last_name: string | null; email: string | null; code: string | null }
    | undefined;
  if (!row || !row.code) return NextResponse.json(GENERIC); // unknown number, inactive, or rate-limited

  const driverName = [row.first_name, row.last_name].filter(Boolean).join(" ") || null;
  let emailed = false;
  if (row.email && EMAIL_PROVIDER_CONFIGURED) {
    const { data: org } = await supabase.from("organizations").select("name").eq("id", row.organization_id).maybeSingle();
    const result = await sendTransactionalEmail({
      to: row.email,
      subject: `Your Driver Portal reset code: ${row.code}`,
      heading: "Reset your Driver Portal PIN",
      organizationName: org?.name ?? "Truck Dispatch Pro",
      text: `Hi${row.first_name ? ` ${row.first_name}` : ""},\n\nYour code to set a new Driver Portal PIN is:\n\n${row.code}\n\nIt works once and expires in 15 minutes. Enter it on the "Forgot PIN" screen with your phone number.\n\nDidn't ask for this? You can ignore this email. Your PIN has not changed.`,
    });
    emailed = result.ok;
    if (!result.ok) console.error("[pin-reset] email failed:", result.error);
  }

  await notifyOfficeOfPinResetRequest(supabase, { organizationId: row.organization_id, driverId: row.driver_id, driverName, emailed });
  return NextResponse.json(GENERIC);
}
