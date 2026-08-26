"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2, CheckCircle2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useToast } from "@/components/ui/toast";
import { DocumentUploadField, type UploadedDocument } from "@/components/driver-application/document-upload-field";
import { saveDriverMedicalCard, attachDriverOnboardingDocument } from "../../actions";

type Application = {
  id: string;
  has_valid_medical_card: boolean | null;
  medical_card_expiry_date: string | null;
  uploaded_documents: UploadedDocument[];
};

// Document/compliance tracking only -- this step never asks about or
// records any medical diagnosis, condition, or exam detail (spec Section
// I: "Do not invent medical diagnosis information"). Just whether a
// current card exists, its expiration date, and a photo/scan of it.
export function MedicalCardForm({ application }: { application: Application }) {
  const toast = useToast();
  const router = useRouter();
  const [saving, startSave] = useTransition();

  const [hasCard, setHasCard] = useState(application.has_valid_medical_card ?? true);
  const [expiry, setExpiry] = useState(application.medical_card_expiry_date ?? "");
  const existingDoc = application.uploaded_documents.find((d) => d.label === "Medical Card") ?? null;
  const [uploadedDoc, setUploadedDoc] = useState<UploadedDocument | null>(existingDoc);

  async function handleUploaded(doc: UploadedDocument) {
    setUploadedDoc(doc);
    const result = await attachDriverOnboardingDocument(doc);
    if (!result.ok) toast.show("error", result.error);
  }

  function handleContinue() {
    startSave(async () => {
      const fd = new FormData();
      fd.set("has_valid_medical_card", hasCard ? "on" : "off");
      fd.set("medical_card_expiry_date", expiry);
      const result = await saveDriverMedicalCard(fd);
      if (!result.ok) { toast.show("error", result.error); return; }
      router.push("/driver-onboarding/employment");
    });
  }

  return (
    <div className="min-w-0 space-y-5 rounded-md border border-desktop-border bg-card p-4 sm:p-5">
      <h2 className="text-[15px] font-semibold text-desktop-text">Medical Card</h2>

      <label className="flex items-center gap-2 text-[13px] text-desktop-text">
        <input type="checkbox" checked={hasCard} onChange={(e) => setHasCard(e.target.checked)} className="size-4" />
        I currently have a valid DOT medical examiner&apos;s certificate
      </label>

      {hasCard && (
        <label className="block min-w-0 max-w-xs space-y-1 text-[12px] font-medium text-desktop-text">
          Expiration date
          <Input type="date" value={expiry} onChange={(e) => setExpiry(e.target.value)} className="w-full min-w-0" />
        </label>
      )}

      <div className="space-y-2 border-t border-desktop-border pt-4">
        <p className="text-[13px] font-semibold text-desktop-text">Medical card photo</p>
        {uploadedDoc && (
          <p className="flex items-center gap-1.5 text-[12px] text-desktop-success">
            <CheckCircle2 className="size-3.5" /> {uploadedDoc.file_name} on file
          </p>
        )}
        <DocumentUploadField label="Medical Card" applicationId={application.id} onUploaded={handleUploaded} />
      </div>

      <div className="flex justify-end border-t border-desktop-border pt-4">
        <Button type="button" disabled={saving} onClick={handleContinue} className="h-11 w-full sm:w-auto">
          {saving ? <Loader2 className="size-4 animate-spin" /> : null} Save &amp; Continue
        </Button>
      </div>
    </div>
  );
}
