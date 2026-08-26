"use client";
import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { useToast } from "@/components/ui/toast";
import { sendBrokerPacket } from "../actions";

// Mirrors carrier-setup-packages' PackageActions send form exactly (same
// controlled inline form, same useTransition + toast + router.refresh()
// pattern) -- this app's one established convention for a compose form
// that must show inline success/error without a page navigation.
export function PacketSendForm(props: {
  brokerId: string;
  packetId: string;
  brokerLegalName: string;
  organizationName: string;
  version: number;
  defaultRecipientEmail: string;
  hasBeenSent: boolean;
  tooLarge: boolean;
}) {
  const [to, setTo] = useState(props.defaultRecipientEmail);
  const [subject, setSubject] = useState(`Broker Packet — ${props.organizationName} — Packet v${props.version}`);
  const [message, setMessage] = useState(
    `Hello,\n\nPlease find attached the Broker Packet for ${props.brokerLegalName} (v${props.version}).\n\nPlease let us know if any additional documentation is required.\n\nRegards,\n${props.organizationName}`
  );
  const [sending, startSend] = useTransition();
  const router = useRouter();
  const toast = useToast();

  if (props.tooLarge) {
    return (
      <section className="min-w-0 rounded-md border bg-card p-4">
        <h2 className="font-semibold">Send to Broker</h2>
        <p className="mt-2 rounded-sm border border-warning/30 bg-warning/5 p-3 text-[12.5px] text-warning">
          This broker packet is too large to email. Download the PDF and send it using your preferred delivery method.
        </p>
      </section>
    );
  }

  return (
    <section className="min-w-0 space-y-3 rounded-md border bg-card p-4">
      <h2 className="font-semibold">{props.hasBeenSent ? "Send Again" : "Send to Broker"}</h2>
      <div className="grid min-w-0 gap-3">
        <label className="block min-w-0 text-sm font-medium">
          To
          <input type="email" value={to} onChange={(e) => setTo(e.target.value)} className="mt-1 h-9 w-full min-w-0 rounded-md border bg-background px-3 text-sm" />
        </label>
        <label className="block min-w-0 text-sm font-medium">
          Subject
          <input value={subject} onChange={(e) => setSubject(e.target.value)} className="mt-1 h-9 w-full min-w-0 rounded-md border bg-background px-3 text-sm" />
        </label>
        <label className="block min-w-0 text-sm font-medium">
          Message
          <textarea value={message} onChange={(e) => setMessage(e.target.value)} rows={7} className="mt-1 w-full min-w-0 rounded-md border bg-background p-2.5 text-sm" />
        </label>
      </div>
      <Button
        disabled={sending || !to.trim() || !subject.trim() || !message.trim()}
        onClick={() =>
          startSend(async () => {
            const result = await sendBrokerPacket(props.brokerId, props.packetId, { to, subject, message, explicitResend: props.hasBeenSent });
            if (!result.ok) toast.show("error", result.error);
            else {
              toast.show("success", "Broker packet sent.");
              router.refresh();
            }
          })
        }
      >
        {sending ? "Sending…" : props.hasBeenSent ? "Send Again" : "Send Packet"}
      </Button>
    </section>
  );
}
