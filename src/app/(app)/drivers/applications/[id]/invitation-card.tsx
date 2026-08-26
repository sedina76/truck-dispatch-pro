"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Copy } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useToast } from "@/components/ui/toast";
import { resendDriverOnboardingInvitation, cancelDriverOnboardingInvitation } from "../actions";

type Invitation = {
  id: string;
  expires_at: string;
  created_at: string;
  first_viewed_at: string | null;
  last_viewed_at: string | null;
  revoked_at: string | null;
  submitted_at: string | null;
};

function fmt(v: string | null) {
  return v ? new Date(v).toLocaleString() : "--";
}

// Phase 2Q.2 -- staff-side invitation status/resend/cancel, shown only for
// applications created via Invite Driver (invited_by is set). Reads
// through getDriverOnboardingInvitations() (a service-role helper, since
// driver_onboarding_invitations has zero client-facing RLS policies by
// design -- see migration 0108's table comment).
export function InvitationCard({ applicationId, status, invitations }: { applicationId: string; status: string; invitations: Invitation[] }) {
  const router = useRouter();
  const toast = useToast();
  const [resending, startResend] = useTransition();
  const [cancelling, startCancel] = useTransition();
  const [copiedUrl, setCopiedUrl] = useState<string | null>(null);

  const latest = invitations[0] ?? null;
  const canResend = ["invited", "in_progress", "needs_correction"].includes(status);
  const canCancel = !["converted", "cancelled", "rejected"].includes(status);

  function handleResend() {
    startResend(async () => {
      const result = await resendDriverOnboardingInvitation(applicationId);
      if (!result.ok) { toast.show("error", result.error); return; }
      toast.show("success", result.emailSent ? "Invitation resent." : "Invitation link regenerated (no email on file to send it to).");
      setCopiedUrl(result.url);
      router.refresh();
    });
  }

  function handleCancel() {
    if (!confirm("Cancel this invitation? The driver's link will stop working.")) return;
    startCancel(async () => {
      const result = await cancelDriverOnboardingInvitation(applicationId);
      if (!result.ok) { toast.show("error", result.error); return; }
      toast.show("success", "Invitation cancelled.");
      router.refresh();
    });
  }

  return (
    <div className="rounded-md border border-desktop-border bg-card p-4">
      <h3 className="text-[14px] font-semibold text-desktop-text">Invitation</h3>
      {latest ? (
        <dl className="mt-2 space-y-1 text-[12.5px]">
          <div className="flex justify-between gap-2"><dt className="text-muted-foreground">Sent</dt><dd>{fmt(latest.created_at)}</dd></div>
          <div className="flex justify-between gap-2"><dt className="text-muted-foreground">Expires</dt><dd>{fmt(latest.expires_at)}</dd></div>
          <div className="flex justify-between gap-2"><dt className="text-muted-foreground">First opened</dt><dd>{fmt(latest.first_viewed_at)}</dd></div>
          <div className="flex justify-between gap-2"><dt className="text-muted-foreground">Submitted</dt><dd>{fmt(latest.submitted_at)}</dd></div>
          {latest.revoked_at && <div className="flex justify-between gap-2"><dt className="text-muted-foreground">Revoked</dt><dd>{fmt(latest.revoked_at)}</dd></div>}
        </dl>
      ) : (
        <p className="mt-1 text-[12.5px] text-muted-foreground">No invitation on record.</p>
      )}

      {copiedUrl && (
        <p className="mt-2 flex items-center gap-1 text-[11.5px] text-muted-foreground">
          <button
            type="button"
            onClick={() => { navigator.clipboard.writeText(copiedUrl); toast.show("success", "Link copied."); }}
            className="flex items-center gap-1 font-medium text-primary hover:underline"
          >
            <Copy className="size-3" /> Copy the new invitation link
          </button>
        </p>
      )}

      <div className="mt-3 flex flex-wrap gap-2">
        {canResend && (
          <Button type="button" size="sm" variant="outline" disabled={resending} onClick={handleResend}>
            {resending ? <Loader2 className="size-3.5 animate-spin" /> : null} Resend Invitation
          </Button>
        )}
        {canCancel && (
          <Button type="button" size="sm" variant="danger" disabled={cancelling} onClick={handleCancel}>
            {cancelling ? <Loader2 className="size-3.5 animate-spin" /> : null} Cancel Invitation
          </Button>
        )}
      </div>
    </div>
  );
}
