"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { generatePacket, type GeneratePacketResult } from "@/app/(app)/invoices/billing-packet-actions";

// Calls generatePacket() directly rather than via a plain <form
// action={...}> -- same reasoning as DocumentLinkButton right next to
// this in the same card: a Server Action's thrown error message is
// redacted to an opaque digest by Next.js in production builds by
// default, so the ONLY way a specific business error ("Could not include
// the Proof of Delivery (file.pdf): the PDF is invalid or unsupported.")
// actually reaches the person clicking the button is for the action to
// RETURN it and this component to display it -- confirmed live: without
// this, the message reached the server log correctly but never the
// browser.
export function GeneratePacketButton({ invoiceId, label }: { invoiceId: string; label: string }) {
  const router = useRouter();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [warning, setWarning] = useState<string | null>(null);

  async function handleClick() {
    setLoading(true);
    setError(null);
    setWarning(null);
    let result: GeneratePacketResult;
    try {
      result = await generatePacket(invoiceId);
    } catch (e) {
      // Belt-and-suspenders: generatePacket() itself no longer throws for
      // any business-rule failure, but a genuinely unexpected error (e.g.
      // a network drop) still could -- never let that hang the button
      // silently or crash the page.
      setError(e instanceof Error ? e.message : "Could not generate the billing packet.");
      setLoading(false);
      return;
    }
    setLoading(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    if (result.skippedDocuments.length > 0) {
      setWarning(`Generated, but could not include: ${result.skippedDocuments.map((d) => `${d.label} (${d.filename})`).join(", ")}. See the packet's cover page for details.`);
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
