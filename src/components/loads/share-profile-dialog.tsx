"use client";

import { useMemo, useState } from "react";
import { Share2, AlertTriangle, Loader2 } from "lucide-react";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import {
  previewProfileShare,
  generateProfileShare,
  sendProfileShareGeneratedEmail,
} from "@/app/(app)/profile-share/actions";
import type { SafeDocumentRef } from "@/lib/profile-share/generate";

type PartyEntity = { id: string; name: string } | null;

export function ShareProfileDialog({
  loadId,
  loadNumber,
  origin,
  destination,
  orgName,
  driver,
  carrier,
  recipientEmail: initialRecipientEmail,
  recipientPartyType,
  availableDocuments,
}: {
  loadId: string;
  loadNumber: string;
  origin: string | null;
  destination: string | null;
  orgName: string;
  driver: PartyEntity;
  carrier: PartyEntity;
  recipientEmail: string;
  recipientPartyType: "broker" | "customer" | null;
  availableDocuments: SafeDocumentRef[];
}) {
  const [open, setOpen] = useState(false);
  const [includeDriver, setIncludeDriver] = useState(!!driver);
  const [includeCarrier, setIncludeCarrier] = useState(!!carrier);
  const [includedDocIds, setIncludedDocIds] = useState<Set<string>>(new Set());
  const [recipientEmail, setRecipientEmail] = useState(initialRecipientEmail);
  const [subject, setSubject] = useState(`Driver/Carrier Profile – Load ${loadNumber}`);
  const [busy, setBusy] = useState<"preview" | "download" | "email" | null>(null);
  const [result, setResult] = useState<{ ok: boolean; text: string } | null>(null);

  const defaultMessage = useMemo(() => {
    const lines = [
      "Hello,",
      "",
      `Please find attached the requested driver/carrier profile for Load ${loadNumber}.`,
      "",
    ];
    if (includeDriver && driver) lines.push(`Driver: ${driver.name}`);
    if (includeCarrier && carrier) lines.push(`Carrier: ${carrier.name}`);
    if (origin) lines.push(`Pickup: ${origin}`);
    if (destination) lines.push(`Delivery: ${destination}`);
    lines.push("", "Please let us know if you need any additional compliance documentation.", "", "Thank you,", orgName);
    return lines.join("\n");
  }, [loadNumber, includeDriver, includeCarrier, driver, carrier, origin, destination, orgName]);
  // null = "use the live-computed default" (tracks checkbox changes); once
  // the user types anything, their text wins and stops following further
  // checkbox changes -- same "suggested but editable" pattern as the
  // toolbar Email dialog.
  const [messageOverride, setMessageOverride] = useState<string | null>(null);
  const message = messageOverride ?? defaultMessage;

  function currentSelection() {
    return {
      loadId,
      driverId: includeDriver && driver ? driver.id : null,
      carrierId: includeCarrier && carrier ? carrier.id : null,
      documentIds: Array.from(includedDocIds),
      recipientEmail,
      recipientPartyType,
    };
  }

  async function handlePreview() {
    setBusy("preview");
    setResult(null);
    try {
      const dataUrl = await previewProfileShare(currentSelection());
      window.open(dataUrl, "_blank", "noopener,noreferrer");
    } catch (e) {
      setResult({ ok: false, text: e instanceof Error ? e.message : "Could not generate a preview." });
    } finally {
      setBusy(null);
    }
  }

  async function handleDownload() {
    setBusy("download");
    setResult(null);
    try {
      const { downloadUrl } = await generateProfileShare(currentSelection());
      if (downloadUrl) window.open(downloadUrl, "_blank", "noopener,noreferrer");
      setResult({ ok: true, text: "Profile generated and recorded in Share History." });
    } catch (e) {
      setResult({ ok: false, text: e instanceof Error ? e.message : "Could not generate the profile PDF." });
    } finally {
      setBusy(null);
    }
  }

  async function handleEmail() {
    setBusy("email");
    setResult(null);
    try {
      const { shareId } = await generateProfileShare(currentSelection());
      const sendResult = await sendProfileShareGeneratedEmail(shareId, loadId, subject, message);
      setResult({
        ok: sendResult.ok,
        text: sendResult.ok ? "Sent." : sendResult.error ?? "Email provider not configured.",
      });
    } catch (e) {
      setResult({ ok: false, text: e instanceof Error ? e.message : "Could not generate/send the profile." });
    } finally {
      setBusy(null);
    }
  }

  function toggleDoc(id: string) {
    setIncludedDocIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  const canSubmit = (includeDriver && !!driver) || (includeCarrier && !!carrier);

  return (
    <>
      <Button type="button" variant="outline" size="sm" onClick={() => setOpen(true)} className="h-7 gap-1.5 px-2.5 text-xs">
        <Share2 className="size-3.5" />
        Share Profile
      </Button>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2 text-[15px]">
              <Share2 className="size-4 text-primary" />
              Share Driver / Carrier Profile
            </DialogTitle>
            <DialogDescription>
              Load {loadNumber}
              {origin || destination ? ` -- ${origin ?? "?"} → ${destination ?? "?"}` : ""}. This sends a broker/
              customer-safe operational profile, never internal staff data.
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-3">
            <Field label="Profiles">
              <div className="flex flex-col gap-1.5">
                <label className={`flex items-center gap-2 text-[13px] ${!driver ? "opacity-40" : ""}`}>
                  <input type="checkbox" checked={includeDriver} disabled={!driver} onChange={(e) => setIncludeDriver(e.target.checked)} />
                  Driver Profile{driver ? ` (${driver.name})` : " -- not assigned"}
                </label>
                <label className={`flex items-center gap-2 text-[13px] ${!carrier ? "opacity-40" : ""}`}>
                  <input type="checkbox" checked={includeCarrier} disabled={!carrier} onChange={(e) => setIncludeCarrier(e.target.checked)} />
                  Carrier Profile{carrier ? ` (${carrier.name})` : " -- not assigned"}
                </label>
              </div>
            </Field>

            {availableDocuments.length > 0 && (
              <Field label="Safe Documents (optional)">
                <div className="flex flex-col gap-1.5">
                  {availableDocuments.map((doc) => (
                    <label key={doc.id} className="flex items-center gap-2 text-[13px]">
                      <input type="checkbox" checked={includedDocIds.has(doc.id)} onChange={() => toggleDoc(doc.id)} />
                      {doc.label}
                      {doc.sensitive && (
                        <span className="flex items-center gap-1 text-[11px] font-medium text-warning">
                          <AlertTriangle className="size-3" />
                          Sensitive -- owner/admin only
                        </span>
                      )}
                    </label>
                  ))}
                </div>
              </Field>
            )}

            <Field label="Recipient Email">
              <input value={recipientEmail} onChange={(e) => setRecipientEmail(e.target.value)} className={inputClass} placeholder="recipient@company.com" />
              {recipientPartyType && <p className="mt-1 text-[11px] text-muted-foreground">Auto-filled from this load&apos;s {recipientPartyType}.</p>}
            </Field>

            <Field label="Subject">
              <input value={subject} onChange={(e) => setSubject(e.target.value)} className={inputClass} />
            </Field>

            <Field label="Message">
              <textarea value={message} onChange={(e) => setMessageOverride(e.target.value)} rows={7} className={inputClass} />
            </Field>
          </div>

          {result && <p className={`text-[12.5px] ${result.ok ? "text-desktop-success" : "text-danger"}`}>{result.text}</p>}
          {!canSubmit && <p className="text-[11.5px] text-warning">Select at least one profile to share.</p>}

          <div className="mt-1 flex items-center justify-end gap-2 border-t border-desktop-border pt-3">
            <Button type="button" variant="outline" size="sm" onClick={() => setOpen(false)}>
              Close
            </Button>
            <Button type="button" variant="outline" size="sm" onClick={handlePreview} disabled={!canSubmit || busy !== null}>
              {busy === "preview" ? <Loader2 className="size-3.5 animate-spin" /> : "Preview"}
            </Button>
            <Button type="button" variant="outline" size="sm" onClick={handleDownload} disabled={!canSubmit || busy !== null}>
              {busy === "download" ? <Loader2 className="size-3.5 animate-spin" /> : "Download PDF"}
            </Button>
            <Button type="button" size="sm" onClick={handleEmail} disabled={!canSubmit || !recipientEmail || busy !== null}>
              {busy === "email" ? <Loader2 className="size-3.5 animate-spin" /> : "Email"}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
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
