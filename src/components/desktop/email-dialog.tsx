"use client";

import { useEffect, useState } from "react";
import { Mail, Paperclip, AlertTriangle } from "lucide-react";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { useDesktopActions } from "@/components/desktop/actions-context";

type Resolved = {
  to: string;
  subject: string;
  message: string;
  attachmentType: string;
  attachmentLabel: string;
  blocked: string | null;
};

// Desktop-ERP compose dialog. Opens with real, server-resolved recipient/
// subject/body/attachment for the current page's registered entity (see
// /api/email/resolve) -- never hard-coded demo values. Send always calls
// /api/email/send; with no email provider configured that always comes
// back "Email provider not configured." and is shown as such, never faked
// as success.
export function DesktopEmailDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (open: boolean) => void }) {
  const { actions } = useDesktopActions();
  const email = actions?.email;

  const [loading, setLoading] = useState(false);
  const [resolved, setResolved] = useState<Resolved | null>(null);
  const [to, setTo] = useState("");
  const [cc, setCc] = useState("");
  const [subject, setSubject] = useState("");
  const [message, setMessage] = useState("");
  const [sendResult, setSendResult] = useState<{ ok: boolean; text: string } | null>(null);
  const [sending, setSending] = useState(false);

  useEffect(() => {
    if (!open || !email) return;
    setLoading(true);
    setSendResult(null);
    fetch("/api/email/resolve", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ entityType: email.entityType, entityId: email.entityId }),
    })
      .then((r) => r.json())
      .then((data: Resolved & { error?: string }) => {
        if (data.error) {
          setResolved({ to: "", subject: "", message: "", attachmentType: "", attachmentLabel: "", blocked: data.error });
          return;
        }
        setResolved(data);
        setTo(data.to);
        setSubject(data.subject);
        setMessage(data.message);
      })
      .finally(() => setLoading(false));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, email?.entityType, email?.entityId]);

  async function handleSend() {
    if (!email) return;
    setSending(true);
    setSendResult(null);
    try {
      const res = await fetch("/api/email/send", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          entityType: email.entityType,
          entityId: email.entityId,
          to,
          cc: cc || undefined,
          subject,
          message,
          attachmentType: resolved?.attachmentType,
        }),
      });
      const data = await res.json();
      setSendResult({ ok: res.ok, text: res.ok ? "Sent." : data.error || "Send failed." });
    } catch {
      setSendResult({ ok: false, text: "Send failed." });
    } finally {
      setSending(false);
    }
  }

  const blocked = resolved?.blocked;
  const canSend = !loading && !sending && !!resolved && !blocked && !!to;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2 text-[15px]">
            <Mail className="size-4 text-primary" />
            Email {actions?.title ?? ""}
          </DialogTitle>
          <DialogDescription>Review the recipient and message before sending.</DialogDescription>
        </DialogHeader>

        {loading ? (
          <p className="py-6 text-center text-sm text-muted-foreground">Loading...</p>
        ) : blocked ? (
          <div className="flex items-start gap-2 rounded-md border border-warning/30 bg-warning/5 px-3 py-2 text-[13px] text-warning">
            <AlertTriangle className="mt-0.5 size-4 shrink-0" />
            {blocked}
          </div>
        ) : (
          <div className="space-y-2.5">
            <Field label="To">
              <input value={to} onChange={(e) => setTo(e.target.value)} className={inputClass} placeholder="No email on file" />
            </Field>
            <Field label="CC (optional)">
              <input value={cc} onChange={(e) => setCc(e.target.value)} className={inputClass} />
            </Field>
            <Field label="Subject">
              <input value={subject} onChange={(e) => setSubject(e.target.value)} className={inputClass} />
            </Field>
            <Field label="Message">
              <textarea value={message} onChange={(e) => setMessage(e.target.value)} rows={7} className={inputClass} />
            </Field>
            {resolved?.attachmentLabel && (
              <div className="flex items-center gap-1.5 rounded-sm border border-desktop-border bg-desktop-muted/50 px-2 py-1.5 text-[12px] text-desktop-text">
                <Paperclip className="size-3.5 shrink-0 text-muted-foreground" />
                Attachment: {resolved.attachmentLabel}
              </div>
            )}
            {!to && <p className="text-[11px] text-warning">No recipient email is on file for this record.</p>}
          </div>
        )}

        {sendResult && (
          <p className={`text-[12.5px] ${sendResult.ok ? "text-desktop-success" : "text-danger"}`}>{sendResult.text}</p>
        )}

        <div className="mt-3 flex items-center justify-end gap-2 border-t border-desktop-border pt-3">
          <Button type="button" variant="outline" size="sm" onClick={() => onOpenChange(false)}>
            Close
          </Button>
          <Button type="button" size="sm" onClick={handleSend} disabled={!canSend}>
            {sending ? "Sending..." : "Send"}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}

const inputClass =
  "w-full rounded-sm border border-desktop-border bg-desktop-panel px-2 py-1.5 text-[13px] text-desktop-text outline-none focus-visible:border-primary focus-visible:ring-1 focus-visible:ring-primary/40";

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1">
      <label className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">{label}</label>
      {children}
    </div>
  );
}
