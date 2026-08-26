import { notFound } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { StatusBadge } from "@/components/ui/status-badge";
import { RevealPiiButton } from "@/components/ui/reveal-pii-button";
import { Button } from "@/components/ui/button";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import {
  updateApplicationReviewNotes,
  revealApplicationSsn,
  convertApplicationToDriver,
  getApplicationDocumentUrl,
  getDriverOnboardingInvitations,
  setDriverApplicationNeedsCorrection,
} from "../actions";
import { InvitationCard } from "./invitation-card";
import { NeedsCorrectionForm } from "./needs-correction-form";
import { DriverW9Card } from "./driver-w9-card";
import { StatusControl } from "./status-control";
import { workerTypeRequiresW9, WORKER_TYPE_LABELS, type DriverWorkerType } from "@/lib/driver-w9/types";
import { DRIVER_W9_STAFF_SAFE_SELECT, type DriverW9Row } from "@/lib/driver-w9/types";

type EmploymentHistoryEntry = {
  employer: string;
  position: string;
  start_date: string;
  end_date: string;
  reason_for_leaving: string;
};

type UploadedDocument = {
  label: string;
  storage_path: string;
  file_name: string;
  uploaded_at: string;
};

function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div>
      <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      {/* div, not p: value can be arbitrary ReactNode (e.g. RevealPiiButton,
          which renders a div), and a div can't legally nest inside a p --
          that's an HTML violation React silently repairs during hydration,
          which is exactly what caused this mismatch. Styling is identical. */}
      <div className="mt-0.5 text-sm">{value ?? "--"}</div>
    </div>
  );
}

function yesNo(value: boolean | null) {
  if (value === null) return "--";
  return value ? "Yes" : "No";
}

export default async function DriverApplicationDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  // Explicit column list, not select("*"): ssn_encrypted is deliberately
  // excluded from the authenticated grant (migration 0018) so it can never
  // be read except through reveal_driver_application_pii(). select("*")
  // asks Postgres for every column including that one, which the role
  // doesn't have -- Postgres then denies the whole query (not just that
  // column), which .single() turns into "no data", which notFound() turns
  // into a misleading 404.
  const [{ data: application }, { data: carriers }] = await Promise.all([
    supabase
      .from("driver_applications")
      .select(
        `id, organization_id, status, position_applied_for, availability,
         first_name, middle_name, last_name, date_of_birth, ssn_last4, phone, email,
         address_line1, city, state, postal_code,
         cdl_number, cdl_state, cdl_class, cdl_endorsements, cdl_expiry_date,
         years_of_experience, equipment_experience, employment_history,
         has_been_convicted_of_dui, has_had_license_suspended, has_had_preventable_accident,
         driving_record_explanation, has_valid_medical_card, medical_card_expiry_date,
         uploaded_documents, emergency_contact_name, emergency_contact_phone,
         signature_name, signature_agreed_at, submitted_from_ip,
         reviewed_by, reviewed_at, review_notes, converted_driver_id,
         invited_by, correction_reason, carrier_id, worker_type, carriers(legal_name),
         submitted_at, updated_at`
      )
      .eq("id", id)
      .single(),
    supabase.from("carriers").select("id, legal_name").eq("is_active", true).order("legal_name"),
  ]);
  if (!application) notFound();

  const employmentHistory = (application.employment_history ?? []) as EmploymentHistoryEntry[];
  const uploadedDocuments = (application.uploaded_documents ?? []) as UploadedDocument[];
  const isConverted = application.status === "converted";
  const isInvitedFlow = Boolean(application.invited_by);
  const isApproved = application.status === "approved";
  const invitations = isInvitedFlow ? await getDriverOnboardingInvitations(id) : [];
  const assignedCarrierName = (application.carriers as unknown as { legal_name: string } | null)?.legal_name ?? null;
  const requiresW9 = workerTypeRequiresW9(application.worker_type as DriverWorkerType | null);
  // .select() built from a shared string constant (DRIVER_W9_STAFF_SAFE_SELECT)
  // defeats supabase-js's column-name type inference (same reasoning as
  // W9_STAFF_SAFE_SELECT's own callers elsewhere) -- cast explicitly to
  // the real row shape rather than the generic-error type it infers.
  const w9Query = requiresW9
    ? await supabase.from("driver_w9s").select(DRIVER_W9_STAFF_SAFE_SELECT).eq("application_id", id).order("created_at", { ascending: false }).limit(1).maybeSingle()
    : { data: null };
  const driverW9 = (w9Query.data as unknown as DriverW9Row | null) ?? null;

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <Link href="/drivers/applications" className="text-xs font-medium text-primary hover:underline">
            &larr; All applications
          </Link>
          <h1 className="mt-1 text-2xl font-semibold tracking-tight">
            {application.first_name} {application.last_name}
          </h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Applied for {application.position_applied_for ?? "a driving position"} &middot; Submitted{" "}
            {new Date(application.submitted_at).toLocaleString()}
          </p>
          {assignedCarrierName && (
            <p className="mt-1 text-sm">
              <span className="text-muted-foreground">Carrier:</span> <span className="font-medium">{assignedCarrierName}</span>
              {application.worker_type && (
                <span className="ml-2 text-muted-foreground">&middot; {WORKER_TYPE_LABELS[application.worker_type as DriverWorkerType]}</span>
              )}
            </p>
          )}
        </div>
        <StatusBadge status={application.status} />
      </div>

      <div className="grid grid-cols-1 gap-5 lg:grid-cols-3">
        <div className="space-y-5 lg:col-span-2">
          <Card>
            <CardHeader>
              <CardTitle>Personal Information</CardTitle>
            </CardHeader>
            <CardContent className="grid grid-cols-2 gap-4 sm:grid-cols-3">
              <Field
                label="Full name"
                value={[application.first_name, application.middle_name, application.last_name].filter(Boolean).join(" ")}
              />
              <Field label="Date of birth" value={application.date_of_birth} />
              <Field
                label="SSN"
                value={
                  application.ssn_last4 ? (
                    <RevealPiiButton
                      maskedValue={`***-**-${application.ssn_last4}`}
                      onReveal={revealApplicationSsn.bind(null, id)}
                      promptForReason
                    />
                  ) : (
                    "Not provided"
                  )
                }
              />
              <Field label="Phone" value={application.phone} />
              <Field label="Email" value={application.email} />
              <Field
                label="Address"
                value={[application.address_line1, application.city, application.state, application.postal_code]
                  .filter(Boolean)
                  .join(", ")}
              />
              <Field label="Position applied for" value={application.position_applied_for} />
              <Field label="Availability" value={application.availability} />
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>CDL &amp; Driving Experience</CardTitle>
            </CardHeader>
            <CardContent className="grid grid-cols-2 gap-4 sm:grid-cols-3">
              <Field label="CDL number" value={application.cdl_number} />
              <Field label="CDL state" value={application.cdl_state} />
              <Field label="CDL class" value={application.cdl_class ? `Class ${application.cdl_class}` : null} />
              <Field label="Endorsements" value={application.cdl_endorsements} />
              <Field label="CDL expiry" value={application.cdl_expiry_date} />
              <Field label="Years of experience" value={application.years_of_experience} />
              <Field label="Equipment experience" value={application.equipment_experience} />
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Employment History</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3">
              {employmentHistory.length === 0 ? (
                <p className="text-sm text-muted-foreground">Not provided.</p>
              ) : (
                employmentHistory.map((entry, i) => (
                  <div key={i} className="rounded-lg border border-border p-3 text-sm">
                    <p className="font-medium">
                      {entry.employer} &middot; {entry.position}
                    </p>
                    <p className="text-xs text-muted-foreground">
                      {entry.start_date || "?"} -- {entry.end_date || "present"}
                    </p>
                    {entry.reason_for_leaving && <p className="mt-1 text-xs">Reason for leaving: {entry.reason_for_leaving}</p>}
                  </div>
                ))
              )}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Driving Record &amp; Medical Card</CardTitle>
              <CardDescription>Self-reported by the applicant; not an automated MVR/background check.</CardDescription>
            </CardHeader>
            <CardContent className="grid grid-cols-2 gap-4 sm:grid-cols-3">
              <Field label="Convicted of DUI/DWI" value={yesNo(application.has_been_convicted_of_dui)} />
              <Field label="License ever suspended" value={yesNo(application.has_had_license_suspended)} />
              <Field label="Preventable accident (3 yrs)" value={yesNo(application.has_had_preventable_accident)} />
              <Field label="Valid medical card" value={yesNo(application.has_valid_medical_card)} />
              <Field label="Medical card expiry" value={application.medical_card_expiry_date} />
              {application.driving_record_explanation && (
                <div className="col-span-full">
                  <Field label="Explanation" value={application.driving_record_explanation} />
                </div>
              )}
            </CardContent>
          </Card>

          {requiresW9 && (
            <Card>
              <CardHeader>
                <CardTitle>Tax (W-9)</CardTitle>
                <CardDescription>Required for this driver&apos;s worker type. Full TIN is never shown here.</CardDescription>
              </CardHeader>
              <CardContent>
                <DriverW9Card w9={driverW9} />
              </CardContent>
            </Card>
          )}

          <Card>
            <CardHeader>
              <CardTitle>Documents</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-wrap gap-2">
              {uploadedDocuments.length === 0 ? (
                <p className="text-sm text-muted-foreground">No documents uploaded.</p>
              ) : (
                uploadedDocuments.map((doc) => (
                  <DocumentLinkButton
                    key={doc.storage_path}
                    label={doc.label}
                    getUrl={getApplicationDocumentUrl.bind(null, id, doc.storage_path)}
                  />
                ))
              )}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Emergency Contact &amp; Signature</CardTitle>
            </CardHeader>
            <CardContent className="grid grid-cols-2 gap-4 sm:grid-cols-3">
              <Field label="Emergency contact" value={application.emergency_contact_name} />
              <Field label="Emergency contact phone" value={application.emergency_contact_phone} />
              <Field label="Electronic signature" value={application.signature_name || null} />
              <Field label="Signed at" value={application.signature_name ? new Date(application.signature_agreed_at).toLocaleString() : null} />
            </CardContent>
          </Card>
        </div>

        <div className="space-y-5">
          {isInvitedFlow && <InvitationCard applicationId={id} status={application.status} invitations={invitations} />}

          <Card>
            <CardHeader>
              <CardTitle>Status</CardTitle>
              <CardDescription>Move this application through your review pipeline.</CardDescription>
            </CardHeader>
            <CardContent>
              {isConverted ? (
                <p className="text-sm text-muted-foreground">
                  This application was hired and converted to a driver record.{" "}
                  {application.converted_driver_id && (
                    <Link href={`/drivers/${application.converted_driver_id}`} className="font-medium text-primary hover:underline">
                      View driver profile &rarr;
                    </Link>
                  )}
                </p>
              ) : (
                <StatusControl applicationId={id} currentStatus={application.status} />
              )}
            </CardContent>
          </Card>

          {!isConverted && application.status === "submitted" && (
            <Card>
              <CardHeader>
                <CardTitle>Needs Correction</CardTitle>
                <CardDescription>Send the driver back to fix something specific, with a note explaining what.</CardDescription>
              </CardHeader>
              <CardContent>
                <NeedsCorrectionForm applicationId={id} action={setDriverApplicationNeedsCorrection} />
              </CardContent>
            </Card>
          )}

          {!isConverted && (
            <Card>
              <CardHeader>
                <CardTitle>Hire &amp; Convert to Driver</CardTitle>
                <CardDescription>
                  Creates a real driver record and securely transfers the encrypted SSN -- it is never decrypted in the
                  process.
                </CardDescription>
              </CardHeader>
              <CardContent>
                {!isApproved ? (
                  <p className="text-sm text-muted-foreground">
                    Set this application&apos;s status to <span className="font-medium text-desktop-text">Approved</span> before it can be converted to a driver record.
                  </p>
                ) : requiresW9 && driverW9?.status !== "completed" ? (
                  <p className="text-sm text-muted-foreground">
                    This driver&apos;s worker type requires a completed Form W-9 before conversion. Current status:{" "}
                    <span className="font-medium text-desktop-text">{driverW9 ? driverW9.status : "not started"}</span>.
                  </p>
                ) : assignedCarrierName ? (
                  // Phase 2Q.2B: carrier is fixed from Invite Driver onward
                  // for a carrier-invited application -- no dropdown, no
                  // reassignment surface at all (Section D/G).
                  <form action={convertApplicationToDriver.bind(null, id)} className="space-y-3">
                    <p className="text-sm">
                      Carrier: <span className="font-medium">{assignedCarrierName}</span>
                    </p>
                    <Button type="submit" variant="success" className="w-full">
                      Hire &amp; Create Driver Record
                    </Button>
                  </form>
                ) : !carriers || carriers.length === 0 ? (
                  <p className="text-sm text-muted-foreground">
                    Add a carrier first before converting an application to a driver.
                  </p>
                ) : (
                  <form action={convertApplicationToDriver.bind(null, id)} className="space-y-3">
                    <select
                      name="carrier_id"
                      required
                      defaultValue=""
                      className="h-10 w-full rounded-lg border border-border bg-card px-3.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
                    >
                      <option value="" disabled>
                        Select a carrier...
                      </option>
                      {carriers.map((c) => (
                        <option key={c.id} value={c.id}>
                          {c.legal_name}
                        </option>
                      ))}
                    </select>
                    <Button type="submit" variant="success" className="w-full">
                      Hire &amp; Create Driver Record
                    </Button>
                  </form>
                )}
              </CardContent>
            </Card>
          )}

          <Card>
            <CardHeader>
              <CardTitle>Review Notes</CardTitle>
              <CardDescription>Internal notes, not visible to the applicant.</CardDescription>
            </CardHeader>
            <CardContent>
              <form action={updateApplicationReviewNotes.bind(null, id)} className="space-y-3">
                <textarea
                  name="review_notes"
                  rows={4}
                  defaultValue={application.review_notes ?? ""}
                  className="w-full rounded-lg border border-border bg-card px-3.5 py-2.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
                />
                <Button type="submit" variant="outline" className="w-full">
                  Save Notes
                </Button>
              </form>
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  );
}
