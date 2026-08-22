"use client";

import { useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2, PenLine } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useToast } from "@/components/ui/toast";
import { cn } from "@/lib/utils";
import { recordInitial, completeSigning, type SigningForCarrier } from "../../actions";

type Signing = SigningForCarrier;

function ClauseCard({ signingId, clause, onInitialed }: { signingId: string; clause: Signing["clauses"][number]; onInitialed: (clauseId: string, value: string) => void }) {
  const toast = useToast();
  const [value, setValue] = useState(clause.typedInitials ?? "");
  const [saving, startSave] = useTransition();
  const [saved, setSaved] = useState(Boolean(clause.typedInitials));

  function handleBlur() {
    if (!clause.requiresInitials) return;
    const trimmed = value.trim();
    if (!trimmed || trimmed.toUpperCase() === (clause.typedInitials ?? "").toUpperCase()) return;
    startSave(async () => {
      const result = await recordInitial(signingId, clause.id, trimmed);
      if (!result.ok) {
        toast.show("error", result.error);
        setSaved(false);
      } else {
        setSaved(true);
        onInitialed(clause.id, trimmed.toUpperCase());
      }
    });
  }

  return (
    <div className="rounded-sm border border-desktop-border p-3">
      <p className="text-[13px] font-semibold text-desktop-text">{clause.title}</p>
      <p className="mt-1 whitespace-pre-wrap text-[12.5px] leading-relaxed text-muted-foreground">{clause.body}</p>
      {clause.requiresInitials && (
        <div className="mt-2 flex items-center gap-2">
          <label className="text-[12px] font-medium text-desktop-text">Initials:</label>
          <Input
            value={value}
            onChange={(e) => {
              setValue(e.target.value);
              setSaved(false);
            }}
            onBlur={handleBlur}
            maxLength={8}
            className="h-8 w-20 text-center uppercase"
            placeholder="XX"
          />
          {saving && <Loader2 className="size-3.5 animate-spin text-muted-foreground" />}
          {!saving && saved && <span className="text-[11px] text-desktop-success">Saved</span>}
        </div>
      )}
    </div>
  );
}

export function AgreementForm({ signing }: { signing: Signing }) {
  const toast = useToast();
  const router = useRouter();
  const [initialedIds, setInitialedIds] = useState<Set<string>>(
    new Set(signing.clauses.filter((c) => c.typedInitials).map((c) => c.id))
  );
  const [consentAccepted, setConsentAccepted] = useState(false);
  const [signerName, setSignerName] = useState("");
  const [signerTitle, setSignerTitle] = useState("");
  const [typedSignature, setTypedSignature] = useState("");
  const [signing_, startSigning] = useTransition();

  const requiredClauseIds = useMemo(() => signing.clauses.filter((c) => c.requiresInitials).map((c) => c.id), [signing.clauses]);
  const allInitialed = requiredClauseIds.every((id) => initialedIds.has(id));
  const canSign =
    allInitialed &&
    consentAccepted &&
    signerName.trim().length > 0 &&
    typedSignature.trim().length > 0 &&
    (!signing.requiresSignerTitle || signerTitle.trim().length > 0);

  function handleSign() {
    startSigning(async () => {
      const result = await completeSigning(signing.signingId, { signerName, signerTitle, typedSignature, consentAccepted });
      if (!result.ok) {
        toast.show("error", result.error);
        return;
      }
      toast.show("success", "Agreement signed.");
      // Stay on this page (rather than jump to Review) -- there may be
      // OTHER active agreements still needing initials/signature (spec
      // section 4/5: multiple distinct required agreements are legal and
      // must each be handled explicitly, never assumed to be "the one").
      router.refresh();
    });
  }

  return (
    <div className="mt-4 space-y-4">
      <div className="max-h-96 space-y-2.5 overflow-y-auto rounded-sm border border-desktop-border bg-desktop-bg p-2.5">
        {signing.clauses.map((clause) => (
          <ClauseCard
            key={clause.id}
            signingId={signing.signingId}
            clause={clause}
            onInitialed={(id) => setInitialedIds((prev) => new Set(prev).add(id))}
          />
        ))}
      </div>

      <div className="rounded-sm border border-desktop-border p-3">
        <label className="flex items-start gap-2 text-[13px] text-desktop-text">
          <input
            type="checkbox"
            checked={consentAccepted}
            onChange={(e) => setConsentAccepted(e.target.checked)}
            className="mt-0.5 size-4 shrink-0 rounded-sm border-desktop-border"
          />
          <span>I agree to use electronic records and signatures for this agreement.</span>
        </label>
        <p className="mt-2 text-[12px] leading-relaxed text-muted-foreground">
          By typing my name below and selecting &quot;Sign Agreement,&quot; I intend my typed name to serve as my
          electronic signature and I agree to be bound by this agreement.
        </p>
      </div>

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <label className="text-[12px] font-medium text-desktop-text">Full Legal Name</label>
          <Input value={signerName} onChange={(e) => setSignerName(e.target.value)} placeholder="John A. Smith" />
        </div>
        {signing.requiresSignerTitle && (
          <div className="space-y-1">
            <label className="text-[12px] font-medium text-desktop-text">Title</label>
            <Input value={signerTitle} onChange={(e) => setSignerTitle(e.target.value)} placeholder="Owner" />
          </div>
        )}
        <div className="space-y-1 sm:col-span-2">
          <label className="text-[12px] font-medium text-desktop-text">Electronic Signature (type your full name)</label>
          <Input
            value={typedSignature}
            onChange={(e) => setTypedSignature(e.target.value)}
            placeholder="JOHN A. SMITH"
            className={cn("font-serif text-base italic tracking-wide", typedSignature && "border-primary")}
          />
        </div>
      </div>

      <div className="flex justify-end border-t border-desktop-border pt-4">
        <Button type="button" disabled={!canSign || signing_} onClick={handleSign}>
          {signing_ ? <Loader2 className="size-3.5 animate-spin" /> : <PenLine className="size-3.5" />}
          {signing_ ? "Signing..." : "Sign Agreement"}
        </Button>
      </div>
      {!allInitialed && requiredClauseIds.length > 0 && (
        <p className="text-right text-[11.5px] text-muted-foreground">Initial every required clause above before signing.</p>
      )}
    </div>
  );
}
