import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { SectionHeading } from "@/components/ui/section-heading";
import type { FactoringCompanyRow, FactoringRelationshipRow } from "@/lib/factoring/types";
import { FactoringSettingsClient } from "./factoring-settings-client";

// Graceful pre-migration behavior, same as settings/email/page.tsx -- a
// PostgREST "relation does not exist" surfaces as { error }, never a
// thrown exception, so this is a plain check rather than a try/catch.
// Not expected to trigger in this phase (0071 is confirmed applied), but
// costs nothing and matches the app's established convention for every
// settings page that reads a migration-gated table.
export default async function FactoringSettingsPage() {
  const supabase = await createClient();
  const orgId = await getCurrentOrgId();

  const [companiesRes, relationshipsRes] = await Promise.all([
    supabase.from("factoring_companies").select("*").eq("organization_id", orgId).order("name"),
    supabase.from("factoring_relationships").select("*").eq("organization_id", orgId).order("created_at"),
  ]);

  const migrationNotApplied = Boolean(companiesRes.error) || Boolean(relationshipsRes.error);
  if (migrationNotApplied) {
    return (
      <div className="space-y-4">
        <SectionHeading title="Factoring" description="Configure factoring companies and commercial terms used when invoices are submitted for funding." />
        <div className="rounded-md border border-dashed border-[var(--color-border)] bg-[var(--color-muted)]/30 p-6 text-sm text-[var(--color-text-muted)]">
          Factoring database migration has not been applied yet. This page will become available once it is. Everything else in Truck Dispatch Pro continues to work normally.
        </div>
      </div>
    );
  }

  const companies = (companiesRes.data ?? []) as FactoringCompanyRow[];
  const relationships = (relationshipsRes.data ?? []) as FactoringRelationshipRow[];

  return (
    <div className="space-y-6">
      <SectionHeading title="Factoring" description="Configure factoring companies and commercial terms used when invoices are submitted for funding." />
      <FactoringSettingsClient companies={companies} relationships={relationships} />
    </div>
  );
}
