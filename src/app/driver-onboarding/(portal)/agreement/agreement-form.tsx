"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";
import { useToast } from "@/components/ui/toast";
import { signDriverOnboardingAgreement } from "../../actions";

type Application = { signature_name: string | null };

// Typed full legal name + explicit certification checkbox -- the same
// electronic-signature pattern already used by the public
// /driver-application form (signature_name/signature_agreed_at,
// migration 0018) and by the carrier W-9 certification step, not a third
// e-signature convention for this codebase.
export function AgreementForm({ application }: { application: Application }) {
  const toast = useToast();
  const router = useRouter();
  const [saving, startSave] = useTransition();
  const [signatureName, setSignatureName] = useState(application.signature_name ?? "");
  const [agreed, setAgreed] = useState(Boolean(application.signature_name));

  function handleContinue() {
    startSave(async () => {
      const fd = new FormData();
      fd.set("signature_name", signatureName);
      if (agreed) fd.set("agreed", "on");
      const result = await signDriverOnboardingAgreement(fd);
      if (!result.ok) { toast.show("error", result.error); return; }
      router.push("/driver-onboarding/review");
    });
  }

  return (
    <div className="min-w-0 space-y-5 rounded-md border border-desktop-border bg-card p-4 sm:p-5">
      <h2 className="text-[15px] font-semibold text-desktop-text">Agreements &amp; Signature</h2>

      <div className="rounded-sm border border-desktop-border bg-desktop-bg p-3 text-[12px] leading-relaxed text-muted-foreground">
        <p className="font-medium text-desktop-text">By signing below, I certify that:</p>
        <p className="mt-1">
          1. All information provided in this onboarding application is true and complete to the best of my knowledge; and
          2. I authorize the company to verify the license, medical card, and other information provided; and
          3. I understand this information will be used to determine my eligibility to drive for this company.
        </p>
      </div>

      <label className="flex min-w-0 items-start gap-2 text-[13px] text-desktop-text">
        <input type="checkbox" checked={agreed} onChange={(e) => setAgreed(e.target.checked)} className="mt-0.5 size-4 shrink-0" />
        <span className="min-w-0 wrap-break-word">I agree to use electronic records and signatures, and I certify the statements above.</span>
      </label>

      <label className="block min-w-0 max-w-sm space-y-1 text-[12px] font-medium text-desktop-text">
        Full legal name (electronic signature)
        <Input
          value={signatureName}
          onChange={(e) => setSignatureName(e.target.value)}
          className={cn("w-full min-w-0 font-serif text-base italic", signatureName && "border-primary")}
        />
      </label>

      <div className="flex justify-end border-t border-desktop-border pt-4">
        <Button type="button" disabled={saving || !agreed || !signatureName.trim()} onClick={handleContinue} className="h-11 w-full sm:w-auto">
          {saving ? <Loader2 className="size-4 animate-spin" /> : null} Save &amp; Continue
        </Button>
      </div>
    </div>
  );
}
