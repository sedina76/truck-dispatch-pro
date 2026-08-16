import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import type { PodStatus } from "@/lib/documents/pod-status";
import { generatePacket, getBillingPacketSignedUrl, sendBillingPacket } from "@/app/(app)/invoices/billing-packet-actions";

type BillingPacket = {
  id: string;
  version: number;
  status: "generated" | "outdated" | "sent";
  storage_path: string;
  generated_at: string;
  sent_at: string | null;
  recipient_email: string | null;
};

const POD_LABEL: Record<PodStatus, string> = {
  missing: "Missing",
  uploaded: "Uploaded (not yet verified)",
  verified: "Verified",
  rejected: "Rejected",
};

function ChecklistLine({ ok, optional, label }: { ok: boolean; optional?: boolean; label: string }) {
  return (
    <p className="flex items-center gap-1.5 text-sm">
      <span className={ok ? "text-success" : optional ? "text-muted-foreground" : "text-danger"}>
        {ok ? "✓" : optional ? "○" : "⚠"}
      </span>
      {label}
    </p>
  );
}

export function BillingPacketSection({
  invoiceId,
  readyToSend,
  podStatus,
  rateConReady,
  bolReady,
  packet,
  packetOutdated,
  defaultRecipientEmail,
  invoiceStatus,
}: {
  invoiceId: string;
  readyToSend: boolean;
  podStatus: PodStatus;
  rateConReady: boolean;
  bolReady: boolean;
  packet: BillingPacket | null;
  packetOutdated: boolean;
  defaultRecipientEmail: string | null;
  invoiceStatus: string;
}) {
  // Status shown to the user: Not Ready / Ready / Generated / Outdated / Sent.
  // "Generated" and "Outdated" only make sense once a packet exists.
  const displayStatus = !readyToSend
    ? "Not Ready"
    : packet?.status === "sent" && !packetOutdated
      ? "Sent"
      : packet && packetOutdated
        ? "Outdated"
        : packet
          ? "Generated"
          : "Ready";

  const statusTone: Record<string, string> = {
    "Not Ready": "bg-danger/10 text-danger",
    Ready: "bg-warning/10 text-warning",
    Generated: "bg-success/10 text-success",
    Outdated: "bg-warning/10 text-warning",
    Sent: "bg-success/10 text-success",
  };

  return (
    <Card>
      <CardHeader className="flex-row items-center justify-between space-y-0">
        <div>
          <CardTitle>Billing Packet</CardTitle>
          <CardDescription>Invoice + supporting documents, merged into one PDF for the broker/customer.</CardDescription>
        </div>
        <span className={`rounded-full px-3 py-1 text-xs font-semibold ${statusTone[displayStatus]}`}>
          {displayStatus.toUpperCase()}
        </span>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="space-y-1.5">
          <ChecklistLine ok label="Invoice" />
          <ChecklistLine ok={podStatus === "verified"} label={`POD — ${POD_LABEL[podStatus]}`} />
          <ChecklistLine ok={rateConReady} optional label={rateConReady ? "Rate Confirmation" : "Rate Confirmation — Optional"} />
          <ChecklistLine ok={bolReady} optional label={bolReady ? "Bill of Lading" : "BOL — Optional"} />
        </div>

        {!readyToSend && (
          <div className="rounded-md border border-danger/30 bg-danger/5 px-3 py-2 text-sm">
            <p className="font-medium text-danger">Billing Packet Not Ready</p>
            <p className="mt-1 text-xs text-muted-foreground">Missing: Verified Proof of Delivery</p>
          </div>
        )}

        {packet && packetOutdated && (
          <div className="rounded-md border border-warning/30 bg-warning/5 px-3 py-2 text-xs text-warning">
            Billing documents have changed since this packet was generated (v{packet.version}). Regenerate before
            sending.
          </div>
        )}

        {packet && (
          <p className="text-xs text-muted-foreground">
            Billing Packet v{packet.version} &middot; Generated {new Date(packet.generated_at).toLocaleString()}
            {packet.sent_at && ` · Sent ${new Date(packet.sent_at).toLocaleString()} to ${packet.recipient_email}`}
          </p>
        )}

        <div className="flex flex-wrap items-center gap-2">
          {readyToSend && (
            <form action={generatePacket.bind(null, invoiceId)}>
              <Button type="submit" size="sm">
                {packet ? "Regenerate Packet" : "Generate Billing Packet"}
              </Button>
            </form>
          )}

          {packet && (
            <>
              <DocumentLinkButton label="Preview Packet" getUrl={getBillingPacketSignedUrl.bind(null, packet.storage_path, false)} />
              <DocumentLinkButton label="Download Packet" getUrl={getBillingPacketSignedUrl.bind(null, packet.storage_path, true)} />
            </>
          )}
        </div>

        {packet && !packetOutdated && invoiceStatus !== "void" && (
          <form action={sendBillingPacket.bind(null, invoiceId, packet.id)} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
            <div className="flex-1 space-y-1">
              <label className="text-xs font-medium">Send to (billing contact)</label>
              <input
                name="recipient_email"
                type="email"
                required
                defaultValue={defaultRecipientEmail ?? ""}
                className="h-9 w-full min-w-[220px] rounded-lg border border-border bg-card px-2.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
              />
            </div>
            <Button type="submit" size="sm" variant="success">
              Send Billing Packet
            </Button>
          </form>
        )}
      </CardContent>
    </Card>
  );
}
