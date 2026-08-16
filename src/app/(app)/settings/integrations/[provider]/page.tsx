import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { IntegrationStatusBadge } from "@/components/integrations/integration-status-badge";
import { PROVIDER_BY_ID, CATEGORY_LABEL, isProviderId } from "@/lib/integrations/registry";
import { deriveIntegrationStatus } from "@/lib/integrations/status";
import { getIntegrationRows, getIntegrationActivity } from "@/lib/integrations/queries";
import { testConnection, setIntegrationEnabled, disconnectIntegration } from "../actions";

function cap(s: string): string {
  return s.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

const ACTIVITY_LABEL: Record<string, string> = {
  connection_test_succeeded: "Connection test succeeded",
  connection_test_failed: "Connection test failed",
  integration_enabled: "Integration enabled",
  integration_disabled: "Integration disabled",
  integration_disconnected: "Integration disconnected",
};

export default async function ProviderDetailPage({ params }: { params: Promise<{ provider: string }> }) {
  const { provider: providerParam } = await params;
  if (!isProviderId(providerParam)) notFound();
  const provider = PROVIDER_BY_ID[providerParam];

  const supabase = await createClient();
  const orgId = await getCurrentOrgId();
  const rows = await getIntegrationRows(supabase, orgId);
  const row = rows.get(provider.id) ?? null;
  const result = deriveIntegrationStatus(provider, row);
  const activity = await getIntegrationActivity(supabase, orgId, row?.id ?? null);

  return (
    <div className="space-y-4">
      <div>
        <Link href="/settings/integrations" className="text-[12px] font-medium text-primary hover:underline">
          &larr; Integrations
        </Link>
      </div>
      <PageHeader title={provider.name} description={provider.description} />

      <Card>
        <CardHeader className="flex-row items-center justify-between space-y-0">
          <div>
            <CardTitle>Overview</CardTitle>
            <CardDescription>{CATEGORY_LABEL[provider.category]}</CardDescription>
          </div>
          <IntegrationStatusBadge result={result} />
        </CardHeader>
        <CardContent className="space-y-3">
          {result.detail && <p className="text-[13px] text-desktop-text-muted">{result.detail}</p>}
          <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 text-[12.5px] sm:grid-cols-3">
            <Field label="Connection Type" value={cap(provider.connectionType)} />
            <Field label="Credential Scope" value={provider.credentialScope === "platform" ? "Platform-wide" : provider.credentialScope === "organization" ? "Per-organization" : "N/A"} />
            <Field label="Test Available" value={provider.supportsTest ? "Yes" : "No"} />
            <Field label="Sync Available" value={provider.supportsSync ? "Yes" : "No"} />
            <Field label="Webhook Available" value={provider.supportsWebhook ? "Yes" : "No"} />
            <Field label="OAuth Available" value={provider.supportsOAuth ? "Yes" : "No"} />
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Capabilities</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="flex flex-wrap gap-1.5">
            {provider.capabilities.map((c) => (
              <span key={c} className="rounded-full bg-muted px-2.5 py-1 text-[11.5px] font-medium text-desktop-text">
                {cap(c)}
              </span>
            ))}
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Setup Requirements</CardTitle>
          <CardDescription>What this integration actually needs to connect.</CardDescription>
        </CardHeader>
        <CardContent>
          {provider.setupRequirements.length > 0 ? (
            <ul className="list-inside list-disc space-y-1 text-[12.5px] text-desktop-text-muted">
              {provider.setupRequirements.map((r) => (
                <li key={r}>{r}</li>
              ))}
            </ul>
          ) : (
            <p className="text-[12.5px] text-muted-foreground">No tenant-level setup applies to this integration.</p>
          )}
        </CardContent>
      </Card>

      {!provider.implemented && (
        <Card>
          <CardHeader>
            <CardTitle>{provider.managedByPlatform ? "Managed by Platform" : "Not Yet Available"}</CardTitle>
          </CardHeader>
          <CardContent>
            <p className="text-[13px] text-desktop-text-muted">{provider.notImplementedReason}</p>
          </CardContent>
        </Card>
      )}

      {provider.implemented && (
        <Card>
          <CardHeader>
            <CardTitle>Connection</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 text-[12.5px] sm:grid-cols-3">
              <Field label="Account" value={row?.account_label ?? "--"} />
              <Field label="Last Connected" value={formatDate(row?.last_connected_at ?? null)} />
              <Field label="Last Tested" value={formatDate(row?.last_tested_at ?? null)} />
              <Field label="Last Test Result" value={row?.last_test_status ? cap(row.last_test_status) : "--"} />
              {row?.last_error_message && <Field label="Last Error" value={row.last_error_message} />}
            </div>

            <div className="flex flex-wrap items-center gap-2 border-t border-desktop-border pt-3">
              {provider.supportsTest && (
                <form action={testConnection.bind(null, provider.id)}>
                  <button type="submit" className="inline-flex h-8 items-center rounded-sm bg-primary px-3 text-[13px] font-medium text-primary-foreground shadow-elevation-1 transition-colors hover:bg-primary-hover">
                    Test Connection
                  </button>
                </form>
              )}
              {row?.is_enabled ? (
                <form action={setIntegrationEnabled.bind(null, provider.id, false)}>
                  <button type="submit" className="inline-flex h-8 items-center rounded-sm border border-danger/30 px-3 text-[13px] font-medium text-danger transition-colors hover:bg-danger/10">
                    Disable
                  </button>
                </form>
              ) : (
                <form action={setIntegrationEnabled.bind(null, provider.id, true)}>
                  <button type="submit" className="inline-flex h-8 items-center rounded-sm border border-desktop-border bg-card px-3 text-[13px] font-medium text-desktop-text transition-colors hover:bg-muted">
                    Enable
                  </button>
                </form>
              )}
              {(row?.last_connected_at || row?.account_label) && !row?.disconnected_at && (
                <form action={disconnectIntegration.bind(null, provider.id)}>
                  <button type="submit" className="inline-flex h-8 items-center rounded-sm border border-danger/30 px-3 text-[13px] font-medium text-danger transition-colors hover:bg-danger/10">
                    Disconnect
                  </button>
                </form>
              )}
            </div>
            {provider.id === "resend" && (
              <p className="text-[11px] text-muted-foreground">
                Enable/Disable here is an organization-level preference tracked for audit purposes. Resend itself is configured platform-wide via server environment variables (RESEND_API_KEY, EMAIL_FROM) -- it does not yet gate whether transactional email actually sends.
              </p>
            )}
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle>Activity</CardTitle>
          <CardDescription>Configuration, test, enable/disable, and disconnect events for this organization. Never includes secret values.</CardDescription>
        </CardHeader>
        <CardContent>
          {activity.length === 0 ? (
            <p className="text-[12.5px] text-muted-foreground">No activity yet.</p>
          ) : (
            <ul className="space-y-2">
              {activity.map((a) => (
                <li key={a.id} className="flex items-center justify-between border-b border-desktop-border pb-1.5 text-[12.5px] last:border-0">
                  <span className="text-desktop-text">{ACTIVITY_LABEL[a.action] ?? cap(a.action)}</span>
                  <span className="text-muted-foreground">
                    {formatDate(a.created_at)}
                    {a.profiles?.full_name ? ` -- ${a.profiles.full_name}` : ""}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className="text-desktop-text">{value}</p>
    </div>
  );
}

function formatDate(iso: string | null): string {
  if (!iso) return "--";
  return new Date(iso).toLocaleString(undefined, { year: "numeric", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}
