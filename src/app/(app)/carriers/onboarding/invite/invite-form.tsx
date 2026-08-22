"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { Copy, CheckCircle2, AlertTriangle, ArrowRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import { FormField, FormGrid } from "@/components/ui/form-field";
import { useToast } from "@/components/ui/toast";
import { inviteCarrier } from "../actions";

export function InviteCarrierForm() {
  const toast = useToast();
  const [pending, startPending] = useTransition();
  const [result, setResult] = useState<{ applicationId: string; url: string; emailSent: boolean } | null>(null);

  function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const formData = new FormData(e.currentTarget);
    startPending(async () => {
      const outcome = await inviteCarrier(formData);
      if (!outcome.ok) {
        toast.show("error", outcome.error);
        return;
      }
      if (outcome.auditWarning) toast.show("info", outcome.auditWarning);
      setResult({ applicationId: outcome.applicationId, url: outcome.url, emailSent: outcome.emailSent });
    });
  }

  if (result) {
    return (
      <div className="max-w-xl rounded-md border border-desktop-border bg-card p-4">
        <div className="flex items-center gap-2 text-desktop-success">
          <CheckCircle2 className="size-5 shrink-0" />
          <p className="text-[14px] font-semibold text-desktop-text">Invitation created</p>
        </div>

        {result.emailSent ? (
          <p className="mt-2 text-[13px] text-muted-foreground">An email with the onboarding link was sent to the carrier.</p>
        ) : (
          <div className="mt-2 flex items-start gap-2 rounded-sm border border-warning/30 bg-warning/10 p-2.5 text-[13px] text-desktop-text">
            <AlertTriangle className="mt-0.5 size-4 shrink-0 text-desktop-warning" />
            <span>Email could not be sent (no provider configured, or delivery failed). Copy the link below and send it to the carrier yourself.</span>
          </div>
        )}

        <div className="mt-3 flex items-center gap-2 rounded-sm border border-desktop-border bg-desktop-bg p-2">
          <code className="flex-1 truncate text-[12px] text-desktop-text">{result.url}</code>
          <Button
            type="button"
            size="sm"
            variant="outline"
            onClick={() => {
              navigator.clipboard?.writeText(result.url).then(() => toast.show("success", "Link copied."));
            }}
          >
            <Copy className="size-3.5" /> Copy
          </Button>
        </div>

        <Link href={`/carriers/onboarding/${result.applicationId}`} className="mt-4 inline-flex items-center gap-1.5 text-[13px] font-medium text-primary hover:underline">
          View Application <ArrowRight className="size-3.5" />
        </Link>
      </div>
    );
  }

  return (
    <form onSubmit={handleSubmit} className="max-w-2xl space-y-4 rounded-md border border-desktop-border bg-card p-4">
      <FormGrid>
        <FormField label="Company Legal Name" name="legal_name" required />
        <FormField label="DBA" name="dba_name" />
        <FormField label="Contact Name" name="contact_name" required />
        <FormField label="Email" name="email" type="email" required />
        <FormField label="Phone" name="phone" type="tel" />
        <FormField label="MC Number" name="mc_number" placeholder="MC-123456" />
        <FormField label="USDOT Number" name="dot_number" placeholder="DOT-1234567" />
      </FormGrid>

      <div className="border-t border-desktop-border pt-3">
        <p className="text-[12.5px] font-semibold text-desktop-text">Proposed Commercial Terms (optional)</p>
        <FormGrid>
          <FormField label="Dispatch Fee %" name="dispatch_fee_percentage" type="number" step="0.01" />
          <FormField label="Payment Terms (days)" name="payment_terms_days" type="number" />
          <FormField label="Factoring Company" name="factoring_company_name" />
        </FormGrid>
        <label className="mt-2 flex items-center gap-2 text-[13px] text-desktop-text">
          <input type="checkbox" name="has_factoring" className="size-4 rounded-sm border-desktop-border" />
          Uses factoring
        </label>
      </div>

      <div className="flex flex-col-reverse gap-2 border-t border-desktop-border pt-4 sm:flex-row sm:justify-end">
        <Link href="/carriers/onboarding" className="inline-flex h-8 items-center rounded-sm px-3 text-[13px] font-medium text-muted-foreground transition-colors hover:bg-muted">
          Cancel
        </Link>
        <Button type="submit" disabled={pending}>
          {pending ? "Sending Invitation..." : "Send Invitation"}
        </Button>
      </div>
    </form>
  );
}
