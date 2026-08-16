import { NextResponse } from "next/server";
import { clearDriverPortalSession } from "@/lib/driver-portal/session";

export async function POST() {
  await clearDriverPortalSession();
  return NextResponse.json({ ok: true });
}
