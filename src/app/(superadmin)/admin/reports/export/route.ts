import { NextResponse } from "next/server";
import { requirePlatformAdmin } from "@/lib/superadmin/require-platform-admin";
import { getPlatformReport } from "@/lib/superadmin/platform-reports";
import { reportCsv } from "@/lib/superadmin/report-rows";

// CSV download of the Reports page's company table. A route handler is its
// own public endpoint (the (superadmin) layout does not wrap it), so it
// re-checks platform-admin access itself before reading anything.
export async function GET() {
  try {
    await requirePlatformAdmin();
  } catch {
    return new NextResponse("Not authorized.", { status: 403 });
  }
  const { rows } = await getPlatformReport();
  const date = new Date().toISOString().slice(0, 10);
  return new NextResponse(reportCsv(rows), {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="truck-dispatch-pro-companies-${date}.csv"`,
      "Cache-Control": "no-store",
    },
  });
}
