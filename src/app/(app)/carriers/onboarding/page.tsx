import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";

type ApplicationRow = {
  id: string;
  legal_name: string | null;
  contact_name: string | null;
  email: string | null;
  mc_number: string | null;
  dot_number: string | null;
  status: string;
  created_at: string;
  updated_at: string;
};

const KPI_STATUSES = ["invited", "in_progress", "needs_correction", "awaiting_approval", "approved", "converted"] as const;

// Phase 2L.4 -- carrier_onboarding_application_status (0081) doesn't have
// a distinct "invited"/"in_progress" pair of its own -- both are the SAME
// underlying 'draft' status, distinguished only by whether the applicant
// has ever actually opened their invitation link (invitations.
// first_viewed_at). Bucketing here at read time keeps that distinction
// purely a display concern, never a second status column to keep in sync
// with the real one.
function kpiBucket(status: string, hasBeenViewed: boolean): (typeof KPI_STATUSES)[number] | null {
  if (status === "draft" || status === "needs_correction") {
    if (status === "needs_correction") return "needs_correction";
    return hasBeenViewed ? "in_progress" : "invited";
  }
  if (status === "submitted") return "awaiting_approval";
  if (status === "approved") return "approved";
  if (status === "converted") return "converted";
  return null; // rejected/cancelled/expired -- not part of the active-funnel KPI row
}

const KPI_LABEL: Record<(typeof KPI_STATUSES)[number], string> = {
  invited: "Invited",
  in_progress: "In Progress",
  needs_correction: "Needs Correction",
  awaiting_approval: "Awaiting Approval",
  approved: "Approved",
  converted: "Converted",
};

export default async function CarrierOnboardingWorkspacePage() {
  const supabase = await createClient();

  const { data } = await supabase
    .from("carrier_onboarding_applications")
    .select("id, legal_name, contact_name, email, mc_number, dot_number, status, created_at, updated_at")
    .order("created_at", { ascending: false });
  const applications = (data ?? []) as ApplicationRow[];

  const applicationIds = applications.map((a) => a.id);
  const { data: invitationRows } = applicationIds.length
    ? await supabase.from("carrier_onboarding_invitations").select("application_id, first_viewed_at").in("application_id", applicationIds)
    : { data: [] as { application_id: string; first_viewed_at: string | null }[] };
  const viewedByApplication = new Set((invitationRows ?? []).filter((r) => r.first_viewed_at).map((r) => r.application_id));

  const kpiCounts: Record<string, number> = {};
  for (const key of KPI_STATUSES) kpiCounts[key] = 0;
  for (const app of applications) {
    const bucket = kpiBucket(app.status, viewedByApplication.has(app.id));
    if (bucket) kpiCounts[bucket]++;
  }

  const columns: Column<ApplicationRow>[] = [
    { header: "Carrier / Company", cell: (row) => <span className="font-medium">{row.legal_name ?? "--"}</span>, sortKey: "legal_name" },
    { header: "Contact", cell: (row) => row.contact_name ?? "--" },
    { header: "MC #", cell: (row) => row.mc_number ?? "--" },
    { header: "USDOT #", cell: (row) => row.dot_number ?? "--" },
    { header: "Status", cell: (row) => <StatusBadge status={row.status} /> },
    { header: "Invited", cell: (row) => new Date(row.created_at).toLocaleDateString(), sortKey: "created_at" },
    { header: "Last Activity", cell: (row) => new Date(row.updated_at).toLocaleDateString(), sortKey: "updated_at" },
  ];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs
        tabs={[
          { label: "Carrier Onboarding", href: "/carriers/onboarding" },
          { label: "Agreement Templates", href: "/carriers/onboarding/templates" },
        ]}
      />
      <PageHeader
        title="Carrier Onboarding"
        description="Invite carriers, collect required documents, execute dispatch agreements, and prepare carriers for activation."
        primaryAction={{ label: "Invite Carrier", href: "/carriers/onboarding/invite" }}
      />

      <DesktopKpiStrip>
        {KPI_STATUSES.map((key) => (
          <DesktopKpiBox key={key} label={KPI_LABEL[key]} value={kpiCounts[key]} />
        ))}
      </DesktopKpiStrip>

      {applications.length === 0 ? (
        <EmptyState title="No carrier applications yet" description="Invite your first carrier to start collecting their onboarding packet." />
      ) : (
        <DataTable columns={columns} rows={applications} getDetailHref={(row) => `/carriers/onboarding/${row.id}`} />
      )}
    </div>
  );
}
