"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { generateCarrierBillingPacket, type CarrierPacketResult } from "@/app/(app)/carrier-invoices/packet-actions";

// Same behavior as GeneratePacketButton on your own invoice: builds and saves
// the packet, shows the exact reason if it can't, then refreshes the page so
// Preview Packet / Download Packet appear.
export function GenerateCarrierPacketButton({ invoiceId, label }: { invoiceId: string; label: string }) {
  const router = useRouter();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [warning, setWarning] = useState<string | null>(null);

  async function handleClick() {
    setLoading(true);
    setError(null);
    setWarning(null);
    let result: CarrierPacketResult;
    try {
      result = await generateCarrierBillingPacket(invoiceId);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not generate the billing packet.");
      setLoading(false);
      return;
    }
    setLoading(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    if (result.skipped.length > 0) {
      setWarning(`Generated, but could not include: ${result.skipped.map((d) => `${d.label} (${d.filename})`).join(", ")}. See the packet's cover page for details.`);
    }
    router.refresh();
  }

  return (
    <div className="flex flex-col gap-1">
      <Button type="button" size="sm" onClick={handleClick} disabled={loading}>
        {loading ? <Loader2 className="size-3.5 animate-spin" /> : null}
        {label}
      </Button>
      {error && <span className="text-xs text-danger">{error}</span>}
      {warning && <span className="text-xs text-warning">{warning}</span>}
    </div>
  );
}
