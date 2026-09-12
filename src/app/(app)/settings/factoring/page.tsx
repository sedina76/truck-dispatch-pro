import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { SectionHeading } from "@/components/ui/section-heading";
import type { OrgRole } from "@/lib/auth/require-role";
import type { CarrierFactoringReadiness, CarrierOption, FactoringCompanyRow, FactoringRelationshipRow } from "@/lib/factoring/types";
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

  // Phase 3B.1.3: carrier-scoped factoring (0136-0139) is a SEPARATE
  // migration boundary from plain factoring existing at all (0071, checked
  // above) -- factoring_companies/factoring_relationships already work
  // fine pre-0136, but carriers.factoring_mode / factoring_relationships.
  // carrier_id / classify_carrier_factoring_readiness() do not exist until
  // 0136-0139 are applied. Probed independently so this page degrades to a
  // clear, honest message for the carrier-aware sections specifically,
  // rather than assuming a column that may not exist yet in production
  // (Phase 3B.1.3's own baseline: 0136-0139 are committed but NOT applied).
  const carrierScopingProbe = await supabase.from("carriers").select("factoring_mode").limit(1);
  const carrierScopingApplied = !carrierScopingProbe.error;

  // Two separate literal `.select()` strings (never one computed via a
  // ternary) -- PostgREST-js parses the select string AT THE TYPE LEVEL,
  // so a computed string collapses to an unparsable literal and every
  // downstream field access fails to typecheck.
  type CarrierScopedRow = { id: string; legal_name: string; is_active: boolean; factoring_mode: CarrierOption["factoring_mode"]; updated_at: string };
  type CarrierBaseRow = { id: string; legal_name: string; is_active: boolean };

  let carriers: CarrierOption[];
  const carrierUpdatedAtById = new Map<string, string>();
  if (carrierScopingApplied) {
    const { data } = await supabase.from("carriers").select("id, legal_name, is_active, factoring_mode, updated_at").eq("organization_id", orgId).order("legal_name");
    const rows = (data ?? []) as CarrierScopedRow[];
    carriers = rows.map((c) => ({ id: c.id, legal_name: c.legal_name, is_active: c.is_active, factoring_mode: c.factoring_mode }));
    for (const c of rows) carrierUpdatedAtById.set(c.id, c.updated_at);
  } else {
    const { data } = await supabase.from("carriers").select("id, legal_name, is_active").eq("organization_id", orgId).order("legal_name");
    const rows = (data ?? []) as CarrierBaseRow[];
    carriers = rows.map((c) => ({ id: c.id, legal_name: c.legal_name, is_active: c.is_active, factoring_mode: null }));
  }

  // Per-carrier readiness, via the SAME read-only classifier the invoice
  // page (Section G) and this page's UI (Section F) both rely on --
  // called once per carrier server-side (small, bounded N; this app has
  // no pagination-scale carrier lists) rather than round-tripping from the
  // client. Never called at all pre-0136 (the function does not exist
  // yet); the UI treats a missing entry as "not yet available."
  const readinessByCarrierId = new Map<string, CarrierFactoringReadiness>();
  if (carrierScopingApplied) {
    await Promise.all(
      carriers.map(async (c) => {
        const { data, error } = await supabase.rpc("classify_carrier_factoring_readiness", { p_carrier_id: c.id });
        if (error || !data || data.success !== true) return;
        readinessByCarrierId.set(c.id, {
          classification: data.classification,
          relationshipId: data.relationship_id ?? null,
          missing: data.missing ?? null,
          message: data.message ?? null,
        });
      })
    );
  }

  const companies = (companiesRes.data ?? []) as FactoringCompanyRow[];
  const relationships = (relationshipsRes.data ?? []) as FactoringRelationshipRow[];

  // Phase 3B.1.4 (Section H): "unauthorized mutation buttons are not
  // shown" -- the client needs the viewer's own role to hide them, never
  // to grant anything itself (every action re-derives and re-checks role
  // server-side regardless of what this prop says).
  const { data: roleData } = await supabase.rpc("current_role");
  const currentRole = (roleData as OrgRole | null) ?? "viewer";

  return (
    <div className="space-y-6">
      <SectionHeading title="Factoring" description="Configure factoring companies and commercial terms used when invoices are submitted for funding." />
      <FactoringSettingsClient
        companies={companies}
        relationships={relationships}
        carriers={carriers}
        carrierScopingApplied={carrierScopingApplied}
        readinessByCarrierId={Object.fromEntries(readinessByCarrierId)}
        carrierUpdatedAtById={Object.fromEntries(carrierUpdatedAtById)}
        currentRole={currentRole}
      />
    </div>
  );
}
