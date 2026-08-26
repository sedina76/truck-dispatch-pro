"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2, CheckCircle2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useToast } from "@/components/ui/toast";
import { DocumentUploadField, type UploadedDocument } from "@/components/driver-application/document-upload-field";
import { saveDriverLicenseInfo, attachDriverOnboardingDocument } from "../../actions";

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block min-w-0 space-y-1 text-[12px] font-medium text-desktop-text">
      {label}
      {children}
    </label>
  );
}

type Application = {
  id: string;
  cdl_number: string | null;
  cdl_state: string | null;
  cdl_class: string | null;
  cdl_endorsements: string | null;
  cdl_expiry_date: string | null;
  uploaded_documents: UploadedDocument[];
};

export function LicenseForm({ application }: { application: Application }) {
  const toast = useToast();
  const router = useRouter();
  const [saving, startSave] = useTransition();

  const [cdlNumber, setCdlNumber] = useState(application.cdl_number ?? "");
  const [cdlState, setCdlState] = useState(application.cdl_state ?? "");
  const [cdlClass, setCdlClass] = useState(application.cdl_class ?? "");
  const [endorsements, setEndorsements] = useState(application.cdl_endorsements ?? "");
  const [expiry, setExpiry] = useState(application.cdl_expiry_date ?? "");
  const cdlDoc = application.uploaded_documents.find((d) => d.label === "CDL") ?? null;
  const [uploadedDoc, setUploadedDoc] = useState<UploadedDocument | null>(cdlDoc);

  async function handleUploaded(doc: UploadedDocument) {
    setUploadedDoc(doc);
    const result = await attachDriverOnboardingDocument(doc);
    if (!result.ok) toast.show("error", result.error);
  }

  function handleContinue() {
    startSave(async () => {
      const fd = new FormData();
      fd.set("cdl_number", cdlNumber);
      fd.set("cdl_state", cdlState);
      fd.set("cdl_class", cdlClass);
      fd.set("cdl_endorsements", endorsements);
      fd.set("cdl_expiry_date", expiry);
      const result = await saveDriverLicenseInfo(fd);
      if (!result.ok) { toast.show("error", result.error); return; }
      router.push("/driver-onboarding/medical-card");
    });
  }

  return (
    <div className="min-w-0 space-y-5 rounded-md border border-desktop-border bg-card p-4 sm:p-5">
      <h2 className="text-[15px] font-semibold text-desktop-text">License / CDL</h2>

      <div className="grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2">
        <Field label="CDL number"><Input value={cdlNumber} onChange={(e) => setCdlNumber(e.target.value)} className="w-full min-w-0" /></Field>
        <Field label="Issuing state"><Input value={cdlState} onChange={(e) => setCdlState(e.target.value)} className="w-full min-w-0" maxLength={2} /></Field>
        <Field label="Class">
          <select value={cdlClass} onChange={(e) => setCdlClass(e.target.value)} className="h-9 w-full min-w-0 rounded-sm border border-desktop-border bg-card px-2 text-[13px]">
            <option value="">Select...</option>
            <option value="A">Class A</option>
            <option value="B">Class B</option>
            <option value="C">Class C</option>
          </select>
        </Field>
        <Field label="Endorsements (if any)"><Input value={endorsements} onChange={(e) => setEndorsements(e.target.value)} className="w-full min-w-0" placeholder="e.g. H, N, T" /></Field>
        <Field label="Expiration date"><Input type="date" value={expiry} onChange={(e) => setExpiry(e.target.value)} className="w-full min-w-0" /></Field>
      </div>

      <div className="space-y-2 border-t border-desktop-border pt-4">
        <p className="text-[13px] font-semibold text-desktop-text">CDL photo</p>
        {uploadedDoc && (
          <p className="flex items-center gap-1.5 text-[12px] text-desktop-success">
            <CheckCircle2 className="size-3.5" /> {uploadedDoc.file_name} on file
          </p>
        )}
        <DocumentUploadField label="CDL" applicationId={application.id} onUploaded={handleUploaded} />
      </div>

      <div className="flex justify-end border-t border-desktop-border pt-4">
        <Button type="button" disabled={saving} onClick={handleContinue} className="h-11 w-full sm:w-auto">
          {saving ? <Loader2 className="size-4 animate-spin" /> : null} Save &amp; Continue
        </Button>
      </div>
    </div>
  );
}
