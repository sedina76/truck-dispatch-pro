import { FileText } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { EmailCarrierButton } from "@/components/dispatch-fee-invoices/email-carrier-button";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import { GenerateCarrierPacketButton } from "@/components/carrier-invoices/generate-carrier-packet-button";
import { getCarrierPacketUrl } from "@/app/(app)/carrier-invoices/packet-actions";
import type { PodStatus } from "@/lib/documents/pod-status";

// The carrier's invoice Billing Packet box -- same look, checklist, status and
// button names as your own invoice's BillingPacketSection. The packet (cover,
// invoice, POD, rate con, BOL and accessorials) is built fresh from the issued
// invoice: "Generate Billing Packet" builds and saves it on the page, then
// Preview Packet / Download Packet / Email appear -- exactly like yours.

const POD_LABEL: Record<PodStatus, string> = {
  missing: "Missing",
  uploaded: "Uploaded (not yet verified)",
  verified: "Verified",
  rejected: "Rejected",
};

function ChecklistLine({ ok, optional, label }: { ok: boolean; optional?: boolean; label: string }) {
  return (
    <p className="flex items-center gap-1.5 text-sm">
      <span className={ok ? "text-success" : optional ? "text-muted-foreground" : "text-danger"}>{ok ? "✓" : optional ? "○" : "⚠"}</span>
      {label}
    </p>
  );
}

const button = "inline-flex h-8 items-center gap-1.5 rounded-sm px-3 text-[13px] font-medium";

export function CarrierBillingPacketSection({
  invoiceId,
  issued,
  voided,
  loads,
  destination,
  lastSent,
  lastError,
  packet,
}: {
  invoiceId: string;
  issued: boolean;
  voided: boolean;
  loads: { loadNumber: string; podStatus: PodStatus; rateConReady: boolean; bolReady: boolean }[];
  /** Where the packet goes, per the carrier's "Who sends the paperwork?" setting (issued invoices only). */
  destination: { who: "carrier" | "factor" | "broker" | "factor_portal"; label: string; settingLabel: string; changeHref: string } | null;
  lastSent: { recipient: string; sentAt: string } | null;
  lastError: string | null;
  /** The saved packet, once generated. */
  packet: { generatedAt: string | null } | null;
}) {
  const podOk = loads.length > 0 && loads.every((l) => l.podStatus === "verified");
  const ready = issued && podOk;
  const displayStatus = voided ? "Void" : !ready ? "Not Ready" : lastSent ? "Sent" : packet ? "Generated" : "Ready";
  const tone: Record<string, string> = {
    Void: "bg-muted text-muted-foreground",
    "Not Ready": "bg-danger/10 text-danger",
    Ready: "bg-warning/10 text-warning",
    Generated: "bg-success/10 text-success",
    Sent: "bg-success/10 text-success",
  };
  const many = loads.length > 1;
  const missing = [!issued && !voided ? "Issue the invoice (button at the top)" : null, !podOk ? "Verified Proof of Delivery" : null].filter(Boolean);

  return (
    <Card>
      <CardHeader className="flex-row items-center justify-between space-y-0">
        <div>
          <CardTitle>Billing Packet</CardTitle>
          <CardDescription>Invoice + supporting documents, merged into one PDF for the factoring company or broker.</CardDescription>
        </div>
        <span className={`rounded-full px-3 py-1 text-xs font-semibold ${tone[displayStatus]}`}>{displayStatus.toUpperCase()}</span>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="space-y-1.5">
          <ChecklistLine ok={issued} label={issued ? "Invoice" : "Invoice — not issued yet"} />
          {loads.map((l) => (
            <div key={l.loadNumber} className="space-y-1.5">
              <ChecklistLine ok={l.podStatus === "verified"} label={`POD${many ? ` (Load ${l.loadNumber})` : ""} — ${POD_LABEL[l.podStatus]}`} />
              <ChecklistLine ok={l.rateConReady} optional label={`${l.rateConReady ? "Rate Confirmation" : "Rate Confirmation — Optional"}${many ? ` (Load ${l.loadNumber})` : ""}`} />
              <ChecklistLine ok={l.bolReady} optional label={`${l.bolReady ? "Bill of Lading" : "BOL — Optional"}${many ? ` (Load ${l.loadNumber})` : ""}`} />
            </div>
          ))}
        </div>

        {voided ? (
          <p className="text-sm text-muted-foreground">This invoice is void.</p>
        ) : !ready ? (
          <div className="rounded-md border border-danger/30 bg-danger/5 px-3 py-2 text-sm">
            <p className="font-medium text-danger">Billing Packet Not Ready</p>
            <p className="mt-1 text-xs text-muted-foreground">Missing: {missing.join("; ")}</p>
          </div>
        ) : null}

        {packet && (
          <p className="text-xs text-muted-foreground">
            Billing Packet &middot; Generated {packet.generatedAt ? new Date(packet.generatedAt).toLocaleString() : ""}
            {lastSent && ` · Sent ${new Date(lastSent.sentAt).toLocaleString()} to ${lastSent.recipient}`}
          </p>
        )}

        <div className="flex flex-wrap items-center gap-2">
          {ready ? (
            <GenerateCarrierPacketButton invoiceId={invoiceId} label={packet ? "Regenerate Packet" : "Generate Billing Packet"} />
          ) : (
            !voided && (
              <Button type="button" size="sm" disabled title={`Missing: ${missing.join("; ")}`}>
                Generate Billing Packet
              </Button>
            )
          )}
          {ready && packet && (
            <>
              <DocumentLinkButton label="Preview Packet" getUrl={getCarrierPacketUrl.bind(null, invoiceId, false)} />
              <DocumentLinkButton label="Download Packet" getUrl={getCarrierPacketUrl.bind(null, invoiceId, true)} />
              <EmailCarrierButton label={lastSent ? "Email Again" : destination?.who === "factor_portal" ? "Email Billing Packet" : `Email to ${destination?.who === "factor" ? "Factor" : destination?.who === "broker" ? "Broker" : "Carrier"}`} />
            </>
          )}
          {issued && (
            <a href={`/carrier-invoices/${invoiceId}/pdf`} target="_blank" rel="noopener" className={`${button} border border-desktop-border hover:bg-muted`}>
              <FileText className="size-4" /> Invoice PDF
            </a>
          )}
        </div>

        {issued && destination && (
          <div className="space-y-1 text-xs text-muted-foreground">
            <p>
              Goes to: <span className="font-medium text-desktop-text">{destination.label}</span> ({destination.settingLabel} --{" "}
              <a href={destination.changeHref} className="text-primary hover:underline">change</a>)
            </p>
            {destination.who === "factor_portal" && <p>This factor takes uploads on its website: download the packet and upload it there (or email it to an address you type in).</p>}
            <p>
              {lastSent ? `Emailed to ${lastSent.recipient} on ${new Date(lastSent.sentAt).toLocaleString()}.` : "Not emailed yet."}
              {lastError && <span className="text-danger"> Last attempt did not send: {lastError}.</span>}
            </p>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
