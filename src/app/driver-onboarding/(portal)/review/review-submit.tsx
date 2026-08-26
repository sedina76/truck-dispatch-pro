"use client";

import Link from "next/link";
import { useState, useTransition } from "react";
import { CheckCircle2, AlertTriangle, Loader2, Pencil } from "lucide-react";
import { Button } from "@/components/ui/button";
import { submitDriverOnboardingApplication } from "../../actions";
import type { UploadedDocument } from "@/components/driver-application/document-upload-field";

type Application = {
  status: string;
  first_name: string;
  middle_name: string | null;
  last_name: string;
  phone: string | null;
  email: string | null;
  address_line1: string | null;
  city: string | null;
  state: string | null;
  postal_code: string | null;
  cdl_number: string | null;
  cdl_state: string | null;
  cdl_class: string | null;
  cdl_expiry_date: string | null;
  has_valid_medical_card: boolean | null;
  medical_card_expiry_date: string | null;
  uploaded_documents: UploadedDocument[];
  signature_name: string | null;
  correction_reason: string | null;
};

function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex items-start justify-between gap-3 border-b border-desktop-border py-1.5 text-[13px] last:border-0">
      <span className="text-muted-foreground">{label}</span>
      <span className="text-right font-medium text-desktop-text">{value ?? "--"}</span>
    </div>
  );
}

export function ReviewSubmit({ application, requiresW9, w9Status }: { application: Application; requiresW9: boolean; w9Status: string | null }) {
  const [submitting, startSubmit] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [submitted, setSubmitted] = useState(application.status !== "in_progress" && application.status !== "needs_correction");

  function handleSubmit() {
    startSubmit(async () => {
      setError(null);
      const result = await submitDriverOnboardingApplication();
      if (!result.ok) { setError(result.error); return; }
      setSubmitted(true);
    });
  }

  if (submitted) {
    return (
      <div className="space-y-3 rounded-md border border-desktop-border bg-card p-5 text-center sm:p-8">
        <CheckCircle2 className="mx-auto size-8 text-desktop-success" />
        <h2 className="text-[16px] font-semibold text-desktop-text">Your application has been submitted</h2>
        <p className="mx-auto max-w-sm text-[13px] text-muted-foreground">
          The company will review your information and be in touch. You can close this page.
        </p>
      </div>
    );
  }

  const cdlDoc = application.uploaded_documents.find((d) => d.label === "CDL");
  const medicalDoc = application.uploaded_documents.find((d) => d.label === "Medical Card");

  return (
    <div className="min-w-0 space-y-5 rounded-md border border-desktop-border bg-card p-4 sm:p-5">
      <h2 className="text-[15px] font-semibold text-desktop-text">Review &amp; Submit</h2>

      {application.status === "needs_correction" && (
        <div className="flex items-start gap-2 rounded-sm border border-warning/40 bg-warning/10 p-3 text-[12.5px] text-desktop-text">
          <AlertTriangle className="mt-0.5 size-3.5 shrink-0 text-warning" />
          <span>
            The company asked for a correction{application.correction_reason ? `: ${application.correction_reason}` : "."} Update the relevant
            step, then submit again.
          </span>
        </div>
      )}

      <section className="space-y-1">
        <div className="flex items-center justify-between">
          <h3 className="text-[12.5px] font-semibold uppercase tracking-wide text-muted-foreground">Personal Information</h3>
          <Link href="/driver-onboarding/personal" className="flex items-center gap-1 text-[12px] font-medium text-primary hover:underline"><Pencil className="size-3" /> Edit</Link>
        </div>
        <Row label="Name" value={[application.first_name, application.middle_name, application.last_name].filter(Boolean).join(" ")} />
        <Row label="Phone" value={application.phone} />
        <Row label="Email" value={application.email} />
        <Row label="Address" value={[application.address_line1, application.city, application.state, application.postal_code].filter(Boolean).join(", ") || null} />
      </section>

      <section className="space-y-1 border-t border-desktop-border pt-3">
        <div className="flex items-center justify-between">
          <h3 className="text-[12.5px] font-semibold uppercase tracking-wide text-muted-foreground">License / CDL</h3>
          <Link href="/driver-onboarding/license" className="flex items-center gap-1 text-[12px] font-medium text-primary hover:underline"><Pencil className="size-3" /> Edit</Link>
        </div>
        <Row label="CDL number" value={application.cdl_number} />
        <Row label="State / Class" value={[application.cdl_state, application.cdl_class ? `Class ${application.cdl_class}` : null].filter(Boolean).join(" / ") || null} />
        <Row label="Expiration" value={application.cdl_expiry_date} />
        <Row label="Photo on file" value={cdlDoc ? cdlDoc.file_name : "Not uploaded"} />
      </section>

      <section className="space-y-1 border-t border-desktop-border pt-3">
        <div className="flex items-center justify-between">
          <h3 className="text-[12.5px] font-semibold uppercase tracking-wide text-muted-foreground">Medical Card</h3>
          <Link href="/driver-onboarding/medical-card" className="flex items-center gap-1 text-[12px] font-medium text-primary hover:underline"><Pencil className="size-3" /> Edit</Link>
        </div>
        <Row label="Valid card" value={application.has_valid_medical_card ? "Yes" : "No"} />
        <Row label="Expiration" value={application.medical_card_expiry_date} />
        <Row label="Photo on file" value={medicalDoc ? medicalDoc.file_name : "Not uploaded"} />
      </section>

      {requiresW9 && (
        <section className="space-y-1 border-t border-desktop-border pt-3">
          <div className="flex items-center justify-between">
            <h3 className="text-[12.5px] font-semibold uppercase tracking-wide text-muted-foreground">Tax (W-9)</h3>
            <Link href="/driver-onboarding/tax-w9" className="flex items-center gap-1 text-[12px] font-medium text-primary hover:underline"><Pencil className="size-3" /> Edit</Link>
          </div>
          <Row label="Status" value={w9Status === "completed" || w9Status === "superseded" ? "Completed" : w9Status === "failed" ? "Generation failed" : "Not completed"} />
        </section>
      )}

      <section className="space-y-1 border-t border-desktop-border pt-3">
        <div className="flex items-center justify-between">
          <h3 className="text-[12.5px] font-semibold uppercase tracking-wide text-muted-foreground">Agreement</h3>
          <Link href="/driver-onboarding/agreement" className="flex items-center gap-1 text-[12px] font-medium text-primary hover:underline"><Pencil className="size-3" /> Edit</Link>
        </div>
        <Row label="Electronic signature" value={application.signature_name} />
      </section>

      {error && (
        <div className="flex items-start gap-2 rounded-sm border border-danger/30 bg-danger/10 p-3 text-[12.5px] text-danger">
          <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
          <span>{error}</span>
        </div>
      )}

      <div className="flex justify-end border-t border-desktop-border pt-4">
        <Button type="button" disabled={submitting} onClick={handleSubmit} className="h-11 w-full sm:w-auto">
          {submitting ? <Loader2 className="size-4 animate-spin" /> : null} Submit Application
        </Button>
      </div>
    </div>
  );
}
