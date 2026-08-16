import Link from "next/link";
import { CATEGORY_LABEL, type ProviderDefinition } from "@/lib/integrations/registry";
import { deriveIntegrationStatus, type IntegrationRow } from "@/lib/integrations/status";
import { IntegrationStatusBadge } from "./integration-status-badge";
import { testConnection, setIntegrationEnabled } from "@/app/(app)/settings/integrations/actions";

function timeAgo(iso: string | null): string | null {
  if (!iso) return null;
  const ms = Date.now() - new Date(iso).getTime();
  const min = Math.round(ms / 60000);
  if (min < 1) return "just now";
  if (min < 60) return `${min}m ago`;
  const hr = Math.round(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.round(hr / 24);
  return `${day}d ago`;
}

// Compact card (spec section 9/38) -- provider, category, description,
// status, connected account, last tested, last sync, and only the actions
// that are actually real for this provider's current state. Never renders
// [Enable] for a provider that still needs real setup (spec section 9),
// and never a [Sync Now] for a provider with no sync capability.
export function ProviderCard({ provider, row }: { provider: ProviderDefinition; row: IntegrationRow }) {
  const result = deriveIntegrationStatus(provider, row);
  const lastTested = timeAgo(row?.last_tested_at ?? null);
  const lastSync = timeAgo(row?.last_synced_at ?? null);

  return (
    <div className="flex flex-col gap-2.5 rounded-lg border border-desktop-border bg-desktop-panel p-3.5">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="truncate text-[13.5px] font-semibold text-desktop-text">{provider.name}</p>
          <p className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">{CATEGORY_LABEL[provider.category]}</p>
        </div>
        <IntegrationStatusBadge result={result} />
      </div>

      <p className="text-[12px] text-desktop-text-muted">{provider.description}</p>

      {result.detail && <p className="text-[11.5px] text-muted-foreground">{result.detail}</p>}

      {provider.implemented && row?.account_label && <p className="text-[11.5px] text-desktop-text">Account: <span className="font-medium">{row.account_label}</span></p>}

      {provider.implemented && (lastTested || lastSync) && (
        <div className="flex flex-wrap gap-x-4 gap-y-0.5 text-[11px] text-muted-foreground">
          {lastTested && <span>Last tested: {lastTested}</span>}
          {provider.supportsSync && lastSync && <span>Last sync: {lastSync}</span>}
        </div>
      )}

      <div className="mt-auto flex flex-wrap items-center gap-1.5 border-t border-desktop-border pt-2.5">
        {provider.implemented ? (
          <>
            <Link
              href={`/settings/integrations/${provider.id}`}
              className="inline-flex h-7 items-center rounded-sm border border-desktop-border bg-card px-2.5 text-[12px] font-medium text-desktop-text transition-colors hover:bg-muted"
            >
              Manage
            </Link>
            {provider.supportsTest && (
              <form action={testConnection.bind(null, provider.id)}>
                <button type="submit" className="inline-flex h-7 items-center rounded-sm border border-desktop-border bg-card px-2.5 text-[12px] font-medium text-desktop-text transition-colors hover:bg-muted">
                  Test Connection
                </button>
              </form>
            )}
            {row?.is_enabled ? (
              <form action={setIntegrationEnabled.bind(null, provider.id, false)}>
                <button type="submit" className="inline-flex h-7 items-center rounded-sm border border-danger/30 px-2.5 text-[12px] font-medium text-danger transition-colors hover:bg-danger/10">
                  Disable
                </button>
              </form>
            ) : (
              <form action={setIntegrationEnabled.bind(null, provider.id, true)}>
                <button type="submit" className="inline-flex h-7 items-center rounded-sm border border-desktop-border bg-card px-2.5 text-[12px] font-medium text-desktop-text transition-colors hover:bg-muted">
                  Enable
                </button>
              </form>
            )}
          </>
        ) : (
          <Link
            href={`/settings/integrations/${provider.id}`}
            className="inline-flex h-7 items-center rounded-sm border border-desktop-border bg-card px-2.5 text-[12px] font-medium text-muted-foreground transition-colors hover:bg-muted"
          >
            {provider.managedByPlatform ? "View Details" : "View Requirements"}
          </Link>
        )}
      </div>
    </div>
  );
}
