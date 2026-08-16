import { NextRequest, NextResponse } from "next/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { createDriverPortalSession } from "@/lib/driver-portal/session";

export async function POST(request: NextRequest) {
  const body = await request.json().catch(() => null);
  const phone = typeof body?.phone === "string" ? body.phone.trim() : "";
  const pin = typeof body?.pin === "string" ? body.pin.trim() : "";

  if (!phone || !pin) {
    return NextResponse.json({ error: "Phone number and PIN are required." }, { status: 400 });
  }

  const supabase = createServiceRoleClient();
  const { data, error } = await supabase.rpc("verify_driver_portal_login", { p_phone: phone, p_pin: pin });

  if (error) {
    if (error.message.includes("account_locked")) {
      return NextResponse.json(
        { error: "Too many failed attempts. Try again in 15 minutes." },
        { status: 423 }
      );
    }
    return NextResponse.json({ error: "Invalid phone number or PIN." }, { status: 401 });
  }

  const identity = Array.isArray(data) ? data[0] : data;
  if (!identity) {
    return NextResponse.json({ error: "Invalid phone number or PIN." }, { status: 401 });
  }

  await createDriverPortalSession(
    identity.driver_id,
    identity.organization_id,
    request.headers.get("user-agent")
  );

  return NextResponse.json({ ok: true });
}
