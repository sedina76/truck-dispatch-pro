import { getPlatformReport } from "@/lib/superadmin/platform-reports";
import { ReportsView } from "@/components/superadmin/reports-view";

export const metadata = { title: "Reports · Platform Console" };

export default async function PlatformReportsPage() {
  return <ReportsView report={await getPlatformReport()} />;
}
