"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2, AlertTriangle } from "lucide-react";
import { Button } from "@/components/ui/button";
import { sendBillingPacket, type SendBillingPacketResult } from "@/app/(app)/invoices/billing-packet-actions";

// Same typed-result pattern as GeneratePacketButton right next to this in
// the same card -- sendBillingPacket() now returns {ok:false, error}
// instead of throwing (Phase 2F, routed through the central send
// pipeline), so this reads that value and shows it inline rather than
// letting a plain <form action={...}> replace the whole page with Next's
// generic error boundary.
export function SendBillingPacketForm({ invoiceId, packetId, defaultRecipientEmail }: { invoiceId: string; packetId: string; defaultRecipientEmail: string | null }) {
  const router = useRouter();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Spec review item 1: an 'uncertain' delivery outcome (the provider's
  // 24h idempotency window expired with no confirmation either way) is
  // NEVER auto-retried -- this flag gates a SEPARATE, explicit "Send
  // Again" action that the person has to deliberately choose, distinct
  // from an ordinary Send click.
  const [uncertain, setUncertain] = useState(false);

  async function submit(forceResend: boolean, formEl: HTMLFormElement) {
    setLoading(true);
    setError(null);
    const formData = new FormData(formEl);
    if (forceResend) formData.set("force_resend", "1");
    let result: SendBillingPacketResult;
    try {
      result = await sendBillingPacket(invoiceId, packetId, formData);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not send the billing packet.");
      setLoading(false);
      return;
    }
    setLoading(false);
    if (!result.ok) {
      setError(result.error);
      setUncertain(Boolean(result.uncertain));
      return;
    }
    setUncertain(false);
    router.refresh();
  }

  return (
    <form onSubmit={(e) => { e.preventDefault(); submit(false, e.currentTarget); }} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
      <div className="flex-1 space-y-1">
        <label className="text-xs font-medium">Send to (billing contact)</label>
        <input
          name="recipient_email"
          type="email"
          required
          defaultValue={defaultRecipientEmail ?? ""}
          disabled={loading}
          className="h-9 w-full min-w-[220px] rounded-lg border border-border bg-card px-2.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20 disabled:opacity-60"
        />
      </div>
      {!uncertain && (
        <Button type="submit" size="sm" variant="success" disabled={loading}>
          {loading ? <Loader2 className="size-3.5 animate-spin" /> : null}
          Send Billing Packet
        </Button>
      )}
      {uncertain && (
        <Button
          type="button"
          size="sm"
          variant="danger"
          disabled={loading}
          onClick={(e) => {
            const formEl = e.currentTarget.closest("form");
            if (formEl) submit(true, formEl);
          }}
        >
          {loading ? <Loader2 className="size-3.5 animate-spin" /> : null}
          Send Again
        </Button>
      )}
      {error && (
        <span className="flex w-full items-start gap-1.5 text-xs text-danger">
          <AlertTriangle className="mt-0.5 size-3.5 shrink-0" /> {error}
        </span>
      )}
    </form>
  );
}
