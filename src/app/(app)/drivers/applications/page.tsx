import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";

type Application = {
  id: string;
  first_name: string;
  last_name: string;
  phone: string | null;
  email: string | null;
  cdl_class: string | null;
  years_of_experience: number | null;
  position_applied_for: string | null;
  status: string;
  submitted_at: string;
};

export default async function DriverApplicationsPage() {
  const supabase = await createClient();

  // RLS (driver_applications_select, migration 0018) already scopes this to
  // the caller's own organization and to owner/admin/dispatcher roles --
  // no manual organization_id filter needed here, same as every other
  // tenant-scoped list page in this app.
  const { data } = await supabase
    .from("driver_applications")
    .select("id, first_name, last_name, phone, email, cdl_class, years_of_experience, position_applied_for, status, submitted_at")
    .order("submitted_at", { ascending: false });

  const applications = (data ?? []) as Application[];

  const newCount = applications.filter((a) => a.status === "submitted").length;
  const underReviewCount = applications.filter((a) => ["under_review", "interview"].includes(a.status)).length;
  const approvedCount = applications.filter((a) => a.status === "approved").length;

  const columns: Column<Application>[] = [
    {
      header: "Applicant",
      cell: (row) => (
        <span className="font-medium">
          {row.first_name} {row.last_name}
        </span>
      ),
    },
    { header: "Phone", cell: (row) => row.phone ?? "--" },
    { header: "Email", cell: (row) => row.email ?? "--" },
    { header: "CDL Class", cell: (row) => (row.cdl_class ? `Class ${row.cdl_class}` : "--") },
    { header: "Experience", cell: (row) => (row.years_of_experience != null ? `${row.years_of_experience} yrs` : "--") },
    { header: "Position", cell: (row) => row.position_applied_for ?? "--" },
    { header: "Status", cell: (row) => <StatusBadge status={row.status} /> },
    { header: "Submitted", cell: (row) => new Date(row.submitted_at).toLocaleDateString() },
  ];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Driver Applications", href: "/drivers/applications" }]} />
      <PageHeader
        title="Driver Applications"
        description="Employment applications submitted through the public /driver-application form."
      />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total Applications" value={applications.length} />
        <DesktopKpiBox label="New" value={newCount} />
        <DesktopKpiBox label="In Review" value={underReviewCount} tone={underReviewCount ? "warning" : "neutral"} />
        <DesktopKpiBox label="Approved" value={approvedCount} tone={approvedCount ? "success" : "neutral"} />
      </DesktopKpiStrip>

      {applications.length === 0 ? (
        <EmptyState
          title="No applications yet"
          description="Applications submitted at /driver-application will show up here, newest first."
        />
      ) : (
        <DataTable columns={columns} rows={applications} getDetailHref={(row) => `/drivers/applications/${row.id}`} />
      )}
    </div>
  );
}
