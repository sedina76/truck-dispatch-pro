import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { SearchBar } from "@/components/ui/search-bar";
import { DesktopKpiBox, DesktopKpiStrip } from "@/components/desktop/kpi-box";
import { ProviderCard } from "@/components/integrations/provider-card";
import { PROVIDERS, CATEGORY_LABEL, type IntegrationCategory } from "@/lib/integrations/registry";
import { deriveIntegrationStatus, computeStatusCounts, statusMatchesFilter, type StatusFilter } from "@/lib/integrations/status";
import { getIntegrationRows } from "@/lib/integrations/queries";
import { cn } from "@/lib/utils";

const STATUS_FILTERS: { value: StatusFilter; label: string }[] = [
  { value: "all", label: "All" },
  { value: "connected", label: "Connected" },
  { value: "needs_setup", label: "Needs Setup" },
  { value: "error", label: "Error" },
  { value: "disabled", label: "Disabled" },
  { value: "coming_soon", label: "Coming Soon" },
];

export default async function IntegrationsSettingsPage({
  searchParams,
}: {
  searchParams: Promise<{ status?: string; category?: string; q?: string }>;
}) {
  const sp = await searchParams;
  const supabase = await createClient();
  const orgId = await getCurrentOrgId();
  const rows = await getIntegrationRows(supabase, orgId);

  const allResults = PROVIDERS.map((p) => ({ provider: p, result: deriveIntegrationStatus(p, rows.get(p.id) ?? null) }));
  const counts = computeStatusCounts(allResults.map((r) => r.result.status));

  const statusFilter: StatusFilter = (sp.status as StatusFilter) || "all";
  const categoryFilter = (sp.category as IntegrationCategory | undefined) || null;
  const q = (sp.q || "").trim().toLowerCase();

  const filtered = allResults.filter(({ provider, result }) => {
    if (!statusMatchesFilter(result.status, statusFilter)) return false;
    if (categoryFilter && provider.category !== categoryFilter) return false;
    if (q && !provider.name.toLowerCase().includes(q) && !provider.description.toLowerCase().includes(q)) return false;
    return true;
  });

  const categories = Array.from(new Set(PROVIDERS.map((p) => p.category))) as IntegrationCategory[];

  function filterHref(next: Partial<{ status: string; category: string }>) {
    const params = new URLSearchParams();
    const status = next.status !== undefined ? next.status : sp.status;
    const category = next.category !== undefined ? next.category : sp.category;
    if (status && status !== "all") params.set("status", status);
    if (category) params.set("category", category);
    if (sp.q) params.set("q", sp.q);
    const qs = params.toString();
    return `/settings/integrations${qs ? `?${qs}` : ""}`;
  }

  return (
    <div className="space-y-4">
      <PageHeader title="Integrations Center" description="Connect load boards, accounting, communications, telematics, and compliance providers." />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Connected" value={counts.connected} tone={counts.connected ? "success" : "neutral"} href={filterHref({ status: "connected" })} />
        <DesktopKpiBox label="Needs Attention" value={counts.needsAttention} tone={counts.needsAttention ? "warning" : "neutral"} href={filterHref({ status: "needs_setup" })} />
        <DesktopKpiBox label="Disabled" value={counts.disabled} tone="neutral" href={filterHref({ status: "disabled" })} />
        <DesktopKpiBox label="Coming Soon" value={counts.comingSoon} tone="neutral" href={filterHref({ status: "coming_soon" })} />
      </DesktopKpiStrip>

      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap items-center gap-1.5">
          {STATUS_FILTERS.map((f) => (
            <Link
              key={f.value}
              href={filterHref({ status: f.value })}
              className={cn(
                "inline-flex h-7 items-center rounded-sm px-2.5 text-[12px] font-medium transition-colors",
                statusFilter === f.value ? "bg-primary text-primary-foreground" : "border border-desktop-border bg-card text-desktop-text hover:bg-muted"
              )}
            >
              {f.label}
            </Link>
          ))}
        </div>
        <SearchBar placeholder="Search providers..." />
      </div>

      <div className="flex flex-wrap items-center gap-1.5">
        <Link
          href={filterHref({ category: "" })}
          className={cn(
            "inline-flex h-6 items-center rounded-full px-2.5 text-[11px] font-medium transition-colors",
            !categoryFilter ? "bg-secondary text-secondary-foreground" : "border border-desktop-border text-muted-foreground hover:bg-muted"
          )}
        >
          All Categories
        </Link>
        {categories.map((c) => (
          <Link
            key={c}
            href={filterHref({ category: c })}
            className={cn(
              "inline-flex h-6 items-center rounded-full px-2.5 text-[11px] font-medium transition-colors",
              categoryFilter === c ? "bg-secondary text-secondary-foreground" : "border border-desktop-border text-muted-foreground hover:bg-muted"
            )}
          >
            {CATEGORY_LABEL[c]}
          </Link>
        ))}
      </div>

      {filtered.length === 0 ? (
        <p className="py-8 text-center text-sm text-muted-foreground">No providers match this filter.</p>
      ) : (
        <div className="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3">
          {filtered.map(({ provider }) => (
            <ProviderCard key={provider.id} provider={provider} row={rows.get(provider.id) ?? null} />
          ))}
        </div>
      )}
    </div>
  );
}
