import { AlertTriangle, CheckCircle2, PlugZap } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { startQuickbooksConnect, disconnectQuickbooks } from "@/app/(app)/settings/integrations/quickbooks-actions";

export type QuickbooksConnectionView = {
  status: "connected" | "reconnect_required" | "disconnected";
  companyName: string | null;
  realmId: string;
  connectedAt: string | null;
  lastRefreshedAt: string | null;
  lastErrorMessage: string | null;
} | null;

function fmt(iso: string | null): string {
  if (!iso) return "--";
  return new Date(iso).toLocaleString(undefined, { year: "numeric", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}

const ERROR_LABEL: Record<string, string> = {
  not_configured: "QuickBooks is not configured on this deployment yet.",
  missing_state: "The connection request was missing its security token. Please try again.",
  missing_code: "QuickBooks did not return an authorization code. Please try again.",
  missing_realm: "QuickBooks did not return a company id. Please try again.",
  invalid_state: "That connection link has expired or was already used. Start again.",
  org_mismatch: "The connection did not match your organization. Start again while signed in to the right organization.",
  access_denied: "Consent was declined in QuickBooks.",
  intuit_error: "QuickBooks reported an error during authorization.",
  exchange_failed: "QuickBooks rejected the authorization. Please try again.",
  token_invalid: "QuickBooks rejected the new access token. Please try again.",
  realm_taken: "That QuickBooks company is already connected to another organization.",
  store_failed: "The connection could not be saved. Please try again.",
  no_org: "No organization context. Sign in and try again.",
};

// The one QuickBooks-specific connection surface, rendered by
// /settings/integrations/quickbooks. It never shows a token or the realm
// id prominently; realm id appears only in a small administrative line.
export function QuickbooksConnectionCard({
  configured,
  redirectUri,
  connection,
  errorCode,
  justConnected,
}: {
  configured: boolean;
  redirectUri: string | null;
  connection: QuickbooksConnectionView;
  errorCode?: string;
  justConnected?: boolean;
}) {
  const isLive = connection && connection.status === "connected";
  const needsReconnect = connection && connection.status === "reconnect_required";

  return (
    <Card>
      <CardHeader className="flex-row items-center justify-between space-y-0">
        <div>
          <CardTitle>QuickBooks Online</CardTitle>
          <CardDescription>Accounting · OAuth 2.0 · Sandbox/Development</CardDescription>
        </div>
        {isLive ? (
          <span className="inline-flex items-center gap-1.5 text-[12px] font-medium text-desktop-success">
            <CheckCircle2 className="size-4" /> Connected
          </span>
        ) : needsReconnect ? (
          <span className="inline-flex items-center gap-1.5 text-[12px] font-medium text-desktop-warning">
            <AlertTriangle className="size-4" /> Reconnect required
          </span>
        ) : (
          <span className="text-[12px] font-medium text-muted-foreground">Not connected</span>
        )}
      </CardHeader>

      <CardContent className="space-y-3">
        {errorCode && (
          <p className="flex items-start gap-2 rounded-sm border border-danger/30 bg-danger/5 p-2.5 text-[12.5px] text-danger">
            <AlertTriangle className="mt-0.5 size-4 shrink-0" />
            {ERROR_LABEL[errorCode] ?? "The QuickBooks connection could not be completed."}
          </p>
        )}
        {justConnected && isLive && (
          <p className="flex items-start gap-2 rounded-sm border border-success/30 bg-success/5 p-2.5 text-[12.5px] text-desktop-success">
            <CheckCircle2 className="mt-0.5 size-4 shrink-0" />
            Connected to {connection?.companyName ?? "your QuickBooks company"}.
          </p>
        )}

        {!configured ? (
          <div className="space-y-2 rounded-sm border border-desktop-border bg-muted/40 p-3 text-[12.5px]">
            <p className="font-medium text-desktop-text">Configuration required</p>
            <p className="text-muted-foreground">
              Set these <span className="font-medium">server-side</span> environment variables (never <code>NEXT_PUBLIC_*</code>), then apply
              migration <code>0116_quickbooks_oauth_foundation.sql</code>:
            </p>
            <ul className="list-inside list-disc space-y-0.5 text-muted-foreground">
              <li><code>QUICKBOOKS_CLIENT_ID</code></li>
              <li><code>QUICKBOOKS_CLIENT_SECRET</code></li>
              <li><code>QUICKBOOKS_ENVIRONMENT=sandbox</code></li>
              <li><code>QUICKBOOKS_REDIRECT_URI</code></li>
            </ul>
            <p className="text-muted-foreground">
              Redirect URI to register in the Intuit Developer portal:
              <br />
              <code className="wrap-break-word">{redirectUri ?? "https://truck-dispatch-pro.vercel.app/api/integrations/quickbooks/callback"}</code>
            </p>
          </div>
        ) : isLive ? (
          <>
            <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 text-[12.5px] sm:grid-cols-3">
              <Field label="Company" value={connection?.companyName ?? "--"} />
              <Field label="Connected" value={fmt(connection?.connectedAt ?? null)} />
              <Field label="Token refreshed" value={fmt(connection?.lastRefreshedAt ?? null)} />
              <Field label="Realm ID" value={connection?.realmId ?? "--"} muted />
              <Field label="Scope" value="Accounting (read/write)" />
            </div>
            <form action={disconnectQuickbooks} className="border-t border-desktop-border pt-3">
              <button
                type="submit"
                className="inline-flex h-8 items-center rounded-sm border border-danger/30 px-3 text-[13px] font-medium text-danger transition-colors hover:bg-danger/10"
              >
                Disconnect
              </button>
            </form>
          </>
        ) : (
          <>
            {needsReconnect && connection?.lastErrorMessage && (
              <p className="text-[12.5px] text-muted-foreground">{connection.lastErrorMessage}</p>
            )}
            <form action={startQuickbooksConnect}>
              <button
                type="submit"
                className="inline-flex h-9 items-center gap-1.5 rounded-sm bg-primary px-3.5 text-[13px] font-medium text-primary-foreground shadow-elevation-1 transition-colors hover:bg-primary-hover"
              >
                <PlugZap className="size-4" />
                {needsReconnect ? "Reconnect QuickBooks" : "Connect QuickBooks"}
              </button>
            </form>
            <p className="text-[11px] text-muted-foreground">
              Opens Intuit&apos;s consent screen. Invoice, customer, and payment sync are not enabled in this phase.
            </p>
          </>
        )}
      </CardContent>
    </Card>
  );
}

function Field({ label, value, muted }: { label: string; value: string; muted?: boolean }) {
  return (
    <div>
      <p className="text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={muted ? "wrap-break-word text-[11px] text-muted-foreground" : "text-desktop-text"}>{value}</p>
    </div>
  );
}
