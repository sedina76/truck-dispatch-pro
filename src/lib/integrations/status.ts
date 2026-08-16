import type { ProviderDefinition } from "./registry";

// The ONE place that decides what status badge an integration shows (spec
// sections 2/43/50). Never derived from is_enabled alone, and never
// duplicated in JSX -- every card/detail page/KPI strip calls
// deriveIntegrationStatus() and renders whatever it returns.

export type IntegrationStatus =
  | "not_configured" // implemented, but never enabled/tested for this org
  | "configured" // implemented + enabled, but never successfully tested
  | "connected" // implemented + enabled + last test succeeded (recently)
  | "degraded" // implemented + enabled + last successful test is stale -- re-verification recommended
  | "error" // implemented + enabled + last test failed
  | "disconnected" // was connected, explicitly disconnected (credentials/tokens cleared)
  | "disabled" // configured before, currently turned off
  | "coming_soon" // no real connector in this codebase yet
  | "api_access_required"; // vendor-gated (DAT/Truckstop/etc.) -- needs vendor-issued credentials, not just "not built yet"

export type IntegrationRow = {
  is_enabled: boolean;
  last_tested_at: string | null;
  last_test_status: string | null;
  last_test_message: string | null;
  last_error_code: string | null;
  last_error_message: string | null;
  last_connected_at: string | null;
  disconnected_at: string | null;
  account_label: string | null;
  external_account_id: string | null;
  last_synced_at: string | null;
  last_sync_status: string | null;
} | null;

// A successful test older than this is shown as "Degraded" (needs
// re-verification) rather than a fully confident "Connected" -- connection
// status is never re-checked on every render (spec section 36), so a very
// stale "success" is treated as weaker evidence, not stale-but-trusted.
const STALE_TEST_DAYS = 30;

export type StatusResult = {
  status: IntegrationStatus;
  label: string;
  detail: string | null;
  tone: "success" | "warning" | "danger" | "neutral";
};

export function deriveIntegrationStatus(provider: ProviderDefinition, row: IntegrationRow): StatusResult {
  if (!provider.implemented) {
    if (provider.managedByPlatform) {
      return { status: "coming_soon", label: "Managed by Platform", detail: provider.notImplementedReason ?? null, tone: "neutral" };
    }
    if (provider.connectionType === "manual") {
      return { status: "api_access_required", label: "API Access Required", detail: provider.notImplementedReason ?? null, tone: "warning" };
    }
    return { status: "coming_soon", label: "Coming Soon", detail: provider.notImplementedReason ?? null, tone: "neutral" };
  }

  if (!row || (!row.is_enabled && !row.last_tested_at && !row.last_connected_at)) {
    return { status: "not_configured", label: "Not Configured", detail: null, tone: "neutral" };
  }

  if (row.disconnected_at) {
    return { status: "disconnected", label: "Disconnected", detail: `Disconnected ${row.disconnected_at}`, tone: "neutral" };
  }

  if (!row.is_enabled) {
    return { status: "disabled", label: "Disabled", detail: "Configuration preserved -- operations are stopped.", tone: "neutral" };
  }

  if (!row.last_test_status) {
    return { status: "configured", label: "Configured", detail: "Not yet tested.", tone: "warning" };
  }

  if (row.last_test_status === "failure") {
    return { status: "error", label: "Error", detail: row.last_error_message ?? row.last_test_message ?? "Last connection test failed.", tone: "danger" };
  }

  const isStale = row.last_tested_at ? Date.now() - new Date(row.last_tested_at).getTime() > STALE_TEST_DAYS * 86400000 : true;
  if (isStale) {
    return { status: "degraded", label: "Needs Attention", detail: "Last successful test was over 30 days ago -- re-test recommended.", tone: "warning" };
  }

  return { status: "connected", label: "Connected", detail: null, tone: "success" };
}

export type StatusFilter = "all" | "connected" | "needs_setup" | "error" | "disabled" | "coming_soon";

export function statusMatchesFilter(status: IntegrationStatus, filter: StatusFilter): boolean {
  switch (filter) {
    case "all":
      return true;
    case "connected":
      return status === "connected";
    case "needs_setup":
      return status === "not_configured" || status === "configured" || status === "api_access_required";
    case "error":
      return status === "error" || status === "degraded";
    case "disabled":
      return status === "disabled" || status === "disconnected";
    case "coming_soon":
      return status === "coming_soon";
  }
}

export type StatusCounts = { connected: number; needsAttention: number; disabled: number; comingSoon: number };

export function computeStatusCounts(results: IntegrationStatus[]): StatusCounts {
  const counts: StatusCounts = { connected: 0, needsAttention: 0, disabled: 0, comingSoon: 0 };
  for (const status of results) {
    if (status === "connected") counts.connected++;
    else if (status === "error" || status === "degraded" || status === "configured" || status === "api_access_required" || status === "not_configured") counts.needsAttention++;
    else if (status === "disabled" || status === "disconnected") counts.disabled++;
    else if (status === "coming_soon") counts.comingSoon++;
  }
  return counts;
}
