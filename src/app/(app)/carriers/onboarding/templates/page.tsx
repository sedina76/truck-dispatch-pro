import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";

type TemplateRow = {
  id: string;
  template_key: string;
  version_number: number;
  name: string;
  status: string;
  is_required_for_onboarding: boolean;
  updated_at: string;
};

export default async function CarrierAgreementTemplatesPage() {
  const supabase = await createClient();
  const { data: roleData } = await supabase.rpc("current_role");
  const canManage = roleData === "owner" || roleData === "admin";

  const { data } = await supabase
    .from("carrier_agreement_templates")
    .select("id, template_key, version_number, name, status, is_required_for_onboarding, updated_at")
    .order("template_key")
    .order("version_number", { ascending: false });

  const templates = (data ?? []) as TemplateRow[];

  const columns: Column<TemplateRow>[] = [
    { header: "Name", cell: (row) => <span className="font-medium">{row.name}</span> },
    { header: "Key", cell: (row) => <span className="text-muted-foreground">{row.template_key}</span> },
    { header: "Version", cell: (row) => `v${row.version_number}` },
    { header: "Status", cell: (row) => <StatusBadge status={row.status} /> },
    { header: "Required for Onboarding", cell: (row) => (row.is_required_for_onboarding ? "Yes" : "No") },
    { header: "Updated", cell: (row) => new Date(row.updated_at).toLocaleDateString() },
  ];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Carrier Onboarding", href: "/carriers/onboarding" }, { label: "Agreement Templates", href: "/carriers/onboarding/templates" }]} />
      <PageHeader
        title="Dispatch Agreement Templates"
        description="Manage the dispatch agreements carriers sign during onboarding. Only owners and admins can create or edit templates."
        primaryAction={canManage ? { label: "New Template", href: "/carriers/onboarding/templates/new" } : undefined}
      />

      {templates.length === 0 ? (
        <EmptyState title="No agreement templates yet" description={canManage ? "Create a template to start collecting dispatch agreement signatures during onboarding." : "No dispatch agreement templates have been configured yet."} />
      ) : (
        <DataTable columns={columns} rows={templates} getDetailHref={(row) => `/carriers/onboarding/templates/${row.id}`} />
      )}
    </div>
  );
}
