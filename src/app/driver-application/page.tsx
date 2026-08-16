"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Truck, CheckCircle2 } from "lucide-react";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { SectionHeading } from "@/components/ui/section-heading";
import { SsnConfirmFields } from "@/components/ui/ssn-confirm-fields";
import { Button } from "@/components/ui/button";
import {
  DocumentUploadField,
  type UploadedDocument,
} from "@/components/driver-application/document-upload-field";
import {
  EmploymentHistoryFields,
  EMPTY_ENTRY,
  type EmploymentHistoryEntry,
} from "@/components/driver-application/employment-history-fields";

const YES_NO_OPTIONS = [
  { value: "no", label: "No" },
  { value: "yes", label: "Yes" },
];

export default function DriverApplicationPage() {
  const router = useRouter();
  const formRef = useRef<HTMLFormElement>(null);
  // Generated once, client-side, the moment the page loads -- lets document
  // uploads attach to this application before the form is actually
  // submitted, since submit_driver_application() accepts (and requires) an
  // explicit id rather than generating one server-side.
  const [applicationId] = useState(() => crypto.randomUUID());

  const [employmentHistory, setEmploymentHistory] = useState<EmploymentHistoryEntry[]>([{ ...EMPTY_ENTRY }]);
  const [uploadedDocuments, setUploadedDocuments] = useState<UploadedDocument[]>([]);
  const [agreedToCertification, setAgreedToCertification] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [submitted, setSubmitted] = useState(false);

  function addUploadedDocument(doc: UploadedDocument) {
    setUploadedDocuments((prev) => [...prev.filter((d) => d.label !== doc.label), doc]);
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!formRef.current) return;
    if (!agreedToCertification) {
      setError("You must certify that this application is accurate before submitting.");
      return;
    }

    setSubmitting(true);
    setError(null);

    const fd = new FormData(formRef.current);
    const get = (name: string) => (fd.get(name) ? String(fd.get(name)) : null);

    const payload = {
      application_id: applicationId,
      position_applied_for: get("position_applied_for"),
      availability: get("availability"),
      first_name: get("first_name"),
      middle_name: get("middle_name"),
      last_name: get("last_name"),
      date_of_birth: get("date_of_birth"),
      ssn: get("ssn"),
      confirm_ssn: get("confirm_ssn"),
      phone: get("phone"),
      email: get("email"),
      address_line1: get("address_line1"),
      city: get("city"),
      state: get("state"),
      postal_code: get("postal_code"),
      cdl_number: get("cdl_number"),
      cdl_state: get("cdl_state"),
      cdl_class: get("cdl_class"),
      cdl_endorsements: get("cdl_endorsements"),
      cdl_expiry_date: get("cdl_expiry_date"),
      years_of_experience: get("years_of_experience"),
      equipment_experience: get("equipment_experience"),
      employment_history: employmentHistory.filter((e) => e.employer.trim() !== ""),
      has_been_convicted_of_dui: get("has_been_convicted_of_dui"),
      has_had_license_suspended: get("has_had_license_suspended"),
      has_had_preventable_accident: get("has_had_preventable_accident"),
      driving_record_explanation: get("driving_record_explanation"),
      has_valid_medical_card: get("has_valid_medical_card"),
      medical_card_expiry_date: get("medical_card_expiry_date"),
      uploaded_documents: uploadedDocuments,
      emergency_contact_name: get("emergency_contact_name"),
      emergency_contact_phone: get("emergency_contact_phone"),
      signature_name: get("signature_name"),
      agreed_to_certification: agreedToCertification,
    };

    try {
      const res = await fetch("/api/driver-application/submit", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      const body = await res.json();
      if (!res.ok) throw new Error(body?.error ?? "Submission failed.");
      setSubmitted(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Submission failed.");
    } finally {
      setSubmitting(false);
    }
  }

  if (submitted) {
    return (
      <div className="flex flex-1 flex-col items-center justify-center py-24 text-center">
        <CheckCircle2 className="size-12 text-success" />
        <h1 className="mt-4 text-xl font-semibold">Application submitted</h1>
        <p className="mt-2 max-w-sm text-sm text-muted-foreground">
          Thank you for applying. A recruiter will review your application and reach out using the
          contact information you provided.
        </p>
        <Button className="mt-6" onClick={() => router.push("/login")}>
          Back to sign in
        </Button>
      </div>
    );
  }

  return (
    <div className="space-y-6 pb-16">
      <div className="mb-2 flex flex-col items-center gap-2 text-center">
        <div className="flex size-12 items-center justify-center rounded-2xl bg-primary/10 text-primary">
          <Truck className="size-6" />
        </div>
        <h1 className="text-xl font-semibold tracking-tight">Driver Employment Application</h1>
        <p className="max-w-md text-sm text-muted-foreground">
          No account needed. Your Social Security Number is encrypted before it&apos;s ever stored and is
          never shown in full to anyone after you submit it.
        </p>
      </div>

      <form ref={formRef} onSubmit={handleSubmit} className="space-y-6 rounded-xl border border-border bg-card p-6 shadow-elevation-1">
        <FormGrid>
          <SectionHeading title="Position" description="What you're applying for." />
          <FormField label="Position applying for" name="position_applied_for" placeholder="Company Driver, OTR" />
          <FormSelect
            label="Availability"
            name="availability"
            options={[
              { value: "full_time", label: "Full-time" },
              { value: "part_time", label: "Part-time" },
              { value: "otr", label: "Over-the-road (OTR)" },
              { value: "regional", label: "Regional" },
              { value: "local", label: "Local" },
              { value: "flexible", label: "Flexible" },
            ]}
          />

          <SectionHeading
            title="Personal Information"
            description="Your SSN is encrypted server-side before it's stored and only ever shown masked to authorized staff."
          />
          <FormField label="First name" name="first_name" required />
          <FormField label="Middle name" name="middle_name" />
          <FormField label="Last name" name="last_name" required />
          <FormField label="Date of birth" name="date_of_birth" type="date" required />
          <SsnConfirmFields required />
          <FormField label="Phone" name="phone" type="tel" required />
          <FormField label="Email" name="email" type="email" required />
          <FormField label="Address" name="address_line1" />
          <FormField label="City" name="city" />
          <FormField label="State" name="state" placeholder="IL" />
          <FormField label="ZIP code" name="postal_code" />

          <SectionHeading title="CDL Information" description="Your commercial driver's license details." />
          <FormField label="CDL number" name="cdl_number" required />
          <FormField label="CDL state" name="cdl_state" placeholder="IL" required />
          <FormSelect
            label="CDL class"
            name="cdl_class"
            options={[
              { value: "A", label: "Class A" },
              { value: "B", label: "Class B" },
              { value: "C", label: "Class C" },
            ]}
          />
          <FormField label="Endorsements" name="cdl_endorsements" placeholder="H, N, T" />
          <FormField label="CDL expiry date" name="cdl_expiry_date" type="date" />

          <SectionHeading title="Driving Experience" description="Your professional driving background." />
          <FormField label="Years of experience" name="years_of_experience" type="number" step="0.5" />
          <FormField label="Equipment experience" name="equipment_experience" placeholder="Dry van, reefer, flatbed" />

          <SectionHeading title="Employment History" description="Add each employer for at least the last 3 years." />
          <EmploymentHistoryFields entries={employmentHistory} onChange={setEmploymentHistory} />

          <SectionHeading
            title="Driving Record"
            description="Self-reported. We do not run an automated background/MVR check as part of this form."
          />
          <FormSelect label="Convicted of DUI/DWI?" name="has_been_convicted_of_dui" options={YES_NO_OPTIONS} />
          <FormSelect label="License ever suspended/revoked?" name="has_had_license_suspended" options={YES_NO_OPTIONS} />
          <FormSelect label="Preventable accident in the last 3 years?" name="has_had_preventable_accident" options={YES_NO_OPTIONS} />
          <FormTextarea label="If yes to any of the above, please explain" name="driving_record_explanation" />

          <SectionHeading title="Medical Card" description="DOT medical certification." />
          <FormSelect label="Do you have a valid medical card?" name="has_valid_medical_card" options={YES_NO_OPTIONS} />
          <FormField label="Medical card expiry date" name="medical_card_expiry_date" type="date" />

          <SectionHeading title="Documents" description="Upload copies of your CDL, medical card, and resume if available." />
          <DocumentUploadField label="CDL copy" applicationId={applicationId} onUploaded={addUploadedDocument} />
          <DocumentUploadField label="Medical card" applicationId={applicationId} onUploaded={addUploadedDocument} />
          <DocumentUploadField label="Resume / driving record" applicationId={applicationId} onUploaded={addUploadedDocument} />

          <SectionHeading title="Emergency Contact" description="Someone we can reach if needed." />
          <FormField label="Emergency contact name" name="emergency_contact_name" />
          <FormField label="Emergency contact phone" name="emergency_contact_phone" type="tel" />
        </FormGrid>

        <div className="space-y-3 border-t border-border pt-6">
          <h2 className="text-sm font-semibold">Electronic Signature</h2>
          <p className="text-xs text-muted-foreground">
            Typing your name below and checking the box constitutes your electronic signature, legally
            binding to the same extent as a handwritten signature.
          </p>
          <FormField label="Type your full legal name to sign" name="signature_name" required />
          <label className="flex items-start gap-2 text-sm">
            <input
              type="checkbox"
              checked={agreedToCertification}
              onChange={(e) => setAgreedToCertification(e.target.checked)}
              className="mt-0.5 size-4 rounded border-border"
            />
            <span>
              I certify that the information provided in this application is true and complete to the
              best of my knowledge, and I understand that any false statement may disqualify me from
              employment or result in dismissal.
            </span>
          </label>
        </div>

        {error && (
          <p className="rounded-md border border-danger/30 bg-danger/10 p-3 text-sm text-danger">{error}</p>
        )}

        <Button type="submit" disabled={submitting} className="w-full">
          {submitting ? "Submitting…" : "Submit Application"}
        </Button>
      </form>
    </div>
  );
}
