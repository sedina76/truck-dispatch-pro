"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { Copy, CheckCircle2, XCircle, Send, Ban, FileWarning, ArrowRightCircle, Loader2, Eye, Download, FilePlus2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { StatusBadge } from "@/components/ui/status-badge";
import { useToast } from "@/components/ui/toast";
import { cn } from "@/lib/utils";
import {
  resendInvitation,
  cancelInvitation,
  requestCorrection,
  approveApplication,
  rejectApplication,
  convertApplication,
  assignAgreementTemplate,
  verifyOnboardingDocument,
  rejectOnboardingDocument,
  getOnboardingDocumentUrl,
  generateExecutedAgreement,
  initializeRequiredAgreements,
  assignMissingRequiredAgreements,
} from "../actions";
import type { RequiredAgreementReadiness } from "@/lib/carrier-agreements/required-readiness";
import { PackageHistory, type PackageHistoryRow } from "./setup-packages/package-history";
import { W9StatusCard } from "@/components/carrier-w9/status-card";
import type { CarrierW9Row } from "@/lib/carrier-w9/types";

export type ApplicationDetailData = {
  id: string;
  status: string;
  legalName: string | null;
  dbaName: string | null;
  mcNumber: string | null;
  dotNumber: string | null;
  contactName: string | null;
  phone: string | null;
  email: string | null;
  addressLine1: string | null;
  addressLine2: string | null;
  city: string | null;
  state: string | null;
  postalCode: string | null;
  country: string | null;
  einLast4: string | null;
  factoringCompanyName: string | null;
  hasFactoring: boolean | null;
  proposedDispatchFeePercentage: number | null;
  proposedPaymentTermsDays: number | null;
  equipmentData: Record<string, unknown> | null;
  reviewNotes: string | null;
  createdAt: string;
  submittedAt: string | null;
  reviewedAt: string | null;
  convertedAt: string | null;
  convertedCarrierId: string | null;
  requiredAgreementReadiness: RequiredAgreementReadiness;
  invitations: { id: string; expiresAt: string; createdAt: string; firstViewedAt: string | null; lastViewedAt: string | null; revokedAt: string | null; submittedAt: string | null }[];
  checklist: { documentType: string; label: string; requirement: "required" | "optional"; documentId: string | null; fileName: string | null; storagePath: string | null; isVerified: boolean; rejectedAt: string | null; rejectionReason: string | null }[];
  signings: {
    id: string;
    status: string;
    templateKey: string;
    templateName: string;
    templateVersion: number;
    isRequiredForOnboarding: boolean;
    signerName: string | null;
    signerTitle: string | null;
    signedAt: string | null;
    evidenceHash: string | null;
    generatedDocumentId: string | null;
    documentGenerationStatus: string;
    documentGenerationFailureReason: string | null;
    clauses: { id: string; title: string; requiresInitials: boolean; typedInitials: string | null }[];
  }[];
  activity: { id: string; action: string; createdAt: string; actorName: string | null; changes: Record<string, unknown> | null }[];
  publishedTemplates: { id: string; template_key: string; name: string; version_number: number }[];
  setupPackages: PackageHistoryRow[];
  w9: CarrierW9Row | null;
  // Phase 2P.3A -- distinct from "w9 is null because none has been
  // started". Set only when the carrier_w9s query itself failed; null
  // w9 with this also null legitimately means no W-9 exists yet.
  w9LoadError: string | null;
  organizationId: string;
};

const TABS = ["Overview", "Company", "Tax (W-9)", "Equipment", "Documents", "Agreement", "Setup Packages", "Activity"] as const;
type Tab = (typeof TABS)[number];

function formatAction(action: string): string {
  return action.split("_").map((w) => w.charAt(0).toUpperCase() + w.slice(1)).join(" ");
}

export function ApplicationDetail({ data, canManage, canConvert, canViewPackages, role }: { data: ApplicationDetailData; canManage: boolean; canConvert: boolean; canViewPackages: boolean; role: string }) {
  const toast = useToast();
  const router = useRouter();
  const [tab, setTab] = useState<Tab>("Overview");
  const [resending, startResend] = useTransition();
  const [cancelling, startCancel] = useTransition();
  const [approving, startApprove] = useTransition();
  const [converting, startConvert] = useTransition();
  const [rejectOpen, setRejectOpen] = useState(false);
  const [correctionOpen, setCorrectionOpen] = useState(false);
  const [rejecting, startReject] = useTransition();
  const [correcting, startCorrect] = useTransition();
  const [inviteLink, setInviteLink] = useState<string | null>(null);
  const visibleTabs = canViewPackages ? TABS : TABS.filter((tab) => tab !== "Setup Packages");

  function refresh() {
    router.refresh();
  }

  function handleResend() {
    startResend(async () => {
      const result = await resendInvitation(data.id);
      if (!result.ok) toast.show("error", result.error);
      else {
        setInviteLink(result.url);
        toast.show(result.auditWarning ? "info" : "success", result.auditWarning ?? (result.emailSent ? "Invitation resent by email." : "New link generated -- email could not be sent, copy it below."));
        refresh();
      }
    });
  }

  function handleCancel() {
    if (!confirm("Cancel this application and revoke its invitation link?")) return;
    startCancel(async () => {
      const result = await cancelInvitation(data.id);
      if (!result.ok) toast.show("error", result.error);
      else {
        toast.show("success", "Application cancelled.");
        refresh();
      }
    });
  }

  function handleApprove() {
    startApprove(async () => {
      const result = await approveApplication(data.id);
      if (!result.ok) toast.show("error", result.error);
      else {
        toast.show("success", "Application approved.");
        refresh();
      }
    });
  }

  function handleConvert() {
    if (!confirm("Convert this application into a real carrier record?")) return;
    startConvert(async () => {
      const result = await convertApplication(data.id);
      if (!result.ok) toast.show("error", result.error);
      else {
        toast.show("success", "Converted to a carrier.");
        router.push(`/carriers/${result.carrierId}`);
      }
    });
  }

  const canResend = ["draft", "needs_correction"].includes(data.status);
  const canCancel = !["converted", "cancelled", "rejected"].includes(data.status);
  const canReview = data.status === "submitted";
  const canConvertNow = data.status === "approved";

  return (
    <div className="space-y-3">
      <div className="rounded-md border border-desktop-border bg-card p-4">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-[16px] font-semibold text-desktop-text">{data.legalName ?? "Untitled Application"}</h1>
              <StatusBadge status={data.status} />
            </div>
            <p className="mt-0.5 text-[12.5px] text-muted-foreground">
              {data.mcNumber ? `MC ${data.mcNumber}` : "MC --"} &nbsp;·&nbsp; {data.dotNumber ? `USDOT ${data.dotNumber}` : "USDOT --"}
            </p>
          </div>
          {canManage && (
            <div className="flex flex-wrap items-center gap-2">
              {canResend && (
                <Button type="button" size="sm" variant="outline" disabled={resending} onClick={handleResend}>
                  <Send className="size-3.5" /> {resending ? "Sending..." : "Resend Invitation"}
                </Button>
              )}
              {canReview && (
                <Button type="button" size="sm" variant="outline" onClick={() => setCorrectionOpen(true)}>
                  <FileWarning className="size-3.5" /> Request Correction
                </Button>
              )}
              {canReview && (
                <Button type="button" size="sm" variant="success" disabled={approving} onClick={handleApprove}>
                  <CheckCircle2 className="size-3.5" /> Approve
                </Button>
              )}
              {canReview && (
                <Button type="button" size="sm" variant="danger" onClick={() => setRejectOpen(true)}>
                  <XCircle className="size-3.5" /> Reject
                </Button>
              )}
              {canConvert && canConvertNow && (
                <Button type="button" size="sm" disabled={converting} onClick={handleConvert}>
                  <ArrowRightCircle className="size-3.5" /> {converting ? "Converting..." : "Convert to Carrier"}
                </Button>
              )}
              {canCancel && (
                <Button type="button" size="sm" variant="ghost" disabled={cancelling} onClick={handleCancel}>
                  <Ban className="size-3.5" /> Cancel
                </Button>
              )}
            </div>
          )}
        </div>

        {inviteLink && (
          <div className="mt-3 flex items-center gap-2 rounded-sm border border-desktop-border bg-desktop-bg p-2">
            <code className="flex-1 truncate text-[12px] text-desktop-text">{inviteLink}</code>
            <Button type="button" size="sm" variant="outline" onClick={() => { navigator.clipboard?.writeText(inviteLink).then(() => toast.show("success", "Link copied.")); }}>
              <Copy className="size-3.5" /> Copy
            </Button>
          </div>
        )}

        {data.status === "converted" && data.convertedCarrierId && (
          <p className="mt-2 text-[12.5px] text-muted-foreground">
            Converted to carrier -- <Link href={`/carriers/${data.convertedCarrierId}`} className="text-primary hover:underline">view carrier record</Link>
          </p>
        )}
      </div>

      {correctionOpen && <ReasonDialog title="Request Correction" label="What needs to be corrected?" onCancel={() => setCorrectionOpen(false)} pending={correcting} onSubmit={(notes) => {
        startCorrect(async () => {
          const result = await requestCorrection(data.id, buildFormData(notes));
          if (!result.ok) toast.show("error", result.error);
          else { toast.show("success", "Correction requested."); setCorrectionOpen(false); refresh(); }
        });
      }} />}

      {rejectOpen && <ReasonDialog title="Reject Application" label="Reason (optional)" required={false} onCancel={() => setRejectOpen(false)} pending={rejecting} onSubmit={(notes) => {
        startReject(async () => {
          const result = await rejectApplication(data.id, buildFormData(notes));
          if (!result.ok) toast.show("error", result.error);
          else { toast.show("success", "Application rejected."); setRejectOpen(false); refresh(); }
        });
      }} />}

      <div className="flex gap-1 overflow-x-auto border-b border-desktop-border">
        {visibleTabs.map((t) => (
          <button
            key={t}
            type="button"
            onClick={() => setTab(t)}
            className={cn(
              "shrink-0 border-b-2 px-3 py-2 text-[13px] font-medium transition-colors",
              tab === t ? "border-primary text-primary" : "border-transparent text-muted-foreground hover:text-desktop-text"
            )}
          >
            {t}
          </button>
        ))}
      </div>

      {tab === "Overview" && <OverviewTab data={data} />}
      {tab === "Company" && <CompanyTab data={data} />}
      {tab === "Tax (W-9)" && (
        data.w9LoadError ? (
          <div className="rounded-md border border-danger/30 bg-danger/5 p-4 text-[13px] text-danger">
            W-9 status could not be loaded: {data.w9LoadError}. This does not mean no W-9 exists -- try reloading the page.
          </div>
        ) : (
          <W9StatusCard w9={data.w9} applicationId={data.id} organizationId={data.organizationId} role={role} pdfRouteBase={`/carriers/onboarding/${data.id}/w9`} />
        )
      )}
      {tab === "Equipment" && <EquipmentTab data={data} />}
      {tab === "Documents" && <DocumentsTab data={data} canManage={canManage} onChanged={refresh} />}
      {tab === "Agreement" && <AgreementTab data={data} canManage={canManage} canGenerate={canConvert} onChanged={refresh} />}
      {tab === "Setup Packages" && <PackageHistory applicationId={data.id} rows={data.setupPackages} canGenerate={canManage && ["approved", "converted"].includes(data.status)} />}
      {tab === "Activity" && <ActivityTab data={data} />}
    </div>
  );
}

function buildFormData(notes: string): FormData {
  const fd = new FormData();
  fd.set("notes", notes);
  return fd;
}

function ReasonDialog({ title, label, required = true, onCancel, onSubmit, pending }: { title: string; label: string; required?: boolean; onCancel: () => void; onSubmit: (notes: string) => void; pending: boolean }) {
  const [notes, setNotes] = useState("");
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/30 p-4">
      <div className="w-full max-w-md rounded-md border border-desktop-border bg-card p-4 shadow-elevation-3">
        <h3 className="text-[14px] font-semibold text-desktop-text">{title}</h3>
        <label className="mt-2 block text-[12px] font-medium text-desktop-text">{label}</label>
        <textarea
          value={notes}
          onChange={(e) => setNotes(e.target.value)}
          rows={4}
          className="mt-1 w-full rounded-sm border border-desktop-border bg-desktop-bg px-2.5 py-2 text-[13px] outline-none focus-visible:border-primary"
        />
        <div className="mt-3 flex justify-end gap-2">
          <Button type="button" size="sm" variant="ghost" onClick={onCancel} disabled={pending}>Cancel</Button>
          <Button type="button" size="sm" disabled={pending || (required && !notes.trim())} onClick={() => onSubmit(notes)}>
            {pending ? "Saving..." : "Submit"}
          </Button>
        </div>
      </div>
    </div>
  );
}

function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div>
      <p className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className="mt-0.5 text-[13.5px] text-desktop-text">{value ?? "--"}</p>
    </div>
  );
}

function OverviewTab({ data }: { data: ApplicationDetailData }) {
  const requiredMissing = data.checklist.filter((c) => c.requirement === "required" && !c.isVerified && !c.documentId).length;
  return (
    <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
      <div className="rounded-md border border-desktop-border bg-card p-4 sm:col-span-2">
        <h2 className="text-[13px] font-semibold text-desktop-text">Summary</h2>
        <div className="mt-3 grid grid-cols-2 gap-3">
          <Field label="Contact" value={data.contactName} />
          <Field label="Email" value={data.email} />
          <Field label="Phone" value={data.phone} />
          <Field label="Invited" value={new Date(data.createdAt).toLocaleString()} />
          <Field label="Submitted" value={data.submittedAt ? new Date(data.submittedAt).toLocaleString() : "Not yet submitted"} />
          <Field label="Reviewed" value={data.reviewedAt ? new Date(data.reviewedAt).toLocaleString() : "--"} />
        </div>
        {data.reviewNotes && (
          <div className="mt-3 rounded-sm border border-desktop-border bg-desktop-bg p-2.5">
            <p className="text-[11px] font-medium uppercase text-muted-foreground">Review Notes</p>
            <p className="mt-0.5 text-[13px] text-desktop-text">{data.reviewNotes}</p>
          </div>
        )}
      </div>
      <div className="space-y-3">
        <div className="rounded-md border border-desktop-border bg-card p-4">
          <p className="text-[11px] font-medium uppercase text-muted-foreground">Documents</p>
          <p className="mt-1 text-[13px] text-desktop-text">{requiredMissing === 0 ? "All required documents on file" : `${requiredMissing} required document${requiredMissing === 1 ? "" : "s"} missing`}</p>
        </div>
        <div className="rounded-md border border-desktop-border bg-card p-4">
          <p className="text-[11px] font-medium uppercase text-muted-foreground">Agreement</p>
          <p className="mt-1 text-[13px] text-desktop-text">
            {data.signings.length === 0
              ? "Not Assigned"
              : `${data.signings.filter((signing) => signing.status === "completed").length} of ${data.signings.length} signed`}
          </p>
        </div>
      </div>
    </div>
  );
}

function CompanyTab({ data }: { data: ApplicationDetailData }) {
  return (
    <div className="rounded-md border border-desktop-border bg-card p-4">
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <Field label="Legal Name" value={data.legalName} />
        <Field label="DBA" value={data.dbaName} />
        <Field label="MC Number" value={data.mcNumber} />
        <Field label="USDOT Number" value={data.dotNumber} />
        <Field label="EIN" value={data.einLast4 ? `•••••${data.einLast4}` : "Not provided"} />
        <Field label="Address" value={[data.addressLine1, data.addressLine2, data.city && data.state ? `${data.city}, ${data.state} ${data.postalCode ?? ""}` : null].filter(Boolean).join(", ") || null} />
        <Field label="Dispatch Fee %" value={data.proposedDispatchFeePercentage != null ? `${data.proposedDispatchFeePercentage}%` : null} />
        <Field label="Payment Terms" value={data.proposedPaymentTermsDays != null ? `${data.proposedPaymentTermsDays} days` : null} />
        <Field label="Factoring" value={data.hasFactoring ? data.factoringCompanyName ?? "Yes" : "No"} />
      </div>
    </div>
  );
}

function EquipmentTab({ data }: { data: ApplicationDetailData }) {
  const eq = data.equipmentData as Record<string, unknown> | null;
  if (!eq) return <div className="rounded-md border border-desktop-border bg-card p-4 text-[13px] text-muted-foreground">No equipment information provided yet.</div>;
  return (
    <div className="rounded-md border border-desktop-border bg-card p-4">
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <Field label="Equipment Type" value={eq.equipment_type as string} />
        <Field label="Truck Count" value={eq.truck_count as number} />
        <Field label="Trailer Count" value={eq.trailer_count as number} />
        <Field label="Trailer Types" value={Array.isArray(eq.trailer_types) ? (eq.trailer_types as string[]).join(", ") : null} />
        <Field label="Operating Regions" value={Array.isArray(eq.operating_regions) ? (eq.operating_regions as string[]).join(", ") : null} />
        <Field label="Preferred Freight" value={eq.preferred_freight as string} />
      </div>
    </div>
  );
}

function DocumentsTab({ data, canManage, onChanged }: { data: ApplicationDetailData; canManage: boolean; onChanged: () => void }) {
  return (
    <div className="space-y-2">
      {data.checklist.map((item) => (
        <DocumentRow key={item.documentType} item={item} applicationId={data.id} canManage={canManage} onChanged={onChanged} />
      ))}
    </div>
  );
}

function DocumentRow({ item, applicationId, canManage, onChanged }: { item: ApplicationDetailData["checklist"][number]; applicationId: string; canManage: boolean; onChanged: () => void }) {
  const toast = useToast();
  const [pending, startPending] = useTransition();
  const [rejectOpen, setRejectOpen] = useState(false);
  const [previewing, startPreview] = useTransition();

  const status = !item.documentId ? "Missing" : item.rejectedAt ? "Rejected" : item.isVerified ? "Accepted" : "Needs Review";
  const tone = status === "Accepted" ? "text-desktop-success" : status === "Rejected" ? "text-desktop-danger" : status === "Missing" ? "text-muted-foreground" : "text-desktop-warning";

  function handlePreview() {
    if (!item.storagePath) return;
    startPreview(async () => {
      try {
        const url = await getOnboardingDocumentUrl(applicationId, item.storagePath!);
        window.open(url, "_blank", "noopener,noreferrer");
      } catch (e) {
        toast.show("error", e instanceof Error ? e.message : "Could not open document.");
      }
    });
  }

  return (
    <div className="flex flex-col gap-2 rounded-sm border border-desktop-border p-3 sm:flex-row sm:items-center sm:justify-between">
      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <span className="text-[13.5px] font-medium text-desktop-text">{item.label}</span>
          {item.requirement === "required" && <span className="text-[10.5px] font-semibold text-danger">Required</span>}
        </div>
        <p className={cn("mt-0.5 text-[12px]", tone)}>{status}{item.fileName ? ` -- ${item.fileName}` : ""}</p>
        {item.rejectionReason && <p className="mt-0.5 text-[12px] text-danger">Reason: {item.rejectionReason}</p>}
      </div>
      <div className="flex shrink-0 items-center gap-2">
        {item.documentId && (
          <Button type="button" size="sm" variant="outline" disabled={previewing} onClick={handlePreview}>
            {previewing ? <Loader2 className="size-3.5 animate-spin" /> : "Preview"}
          </Button>
        )}
        {canManage && item.documentId && !item.isVerified && (
          <Button type="button" size="sm" variant="success" disabled={pending} onClick={() => {
            startPending(async () => {
              const result = await verifyOnboardingDocument(item.documentId!, applicationId);
              if (!result.ok) toast.show("error", result.error);
              else { toast.show("success", "Accepted."); onChanged(); }
            });
          }}>
            Accept
          </Button>
        )}
        {canManage && item.documentId && !item.rejectedAt && (
          <Button type="button" size="sm" variant="danger" onClick={() => setRejectOpen(true)}>
            Reject
          </Button>
        )}
      </div>
      {rejectOpen && (
        <ReasonDialog title={`Reject ${item.label}`} label="Reason for rejection" onCancel={() => setRejectOpen(false)} pending={pending} onSubmit={(reason) => {
          startPending(async () => {
            const result = await rejectOnboardingDocument(item.documentId!, applicationId, buildFormData(reason));
            if (!result.ok) toast.show("error", result.error);
            else { toast.show("success", "Rejected."); setRejectOpen(false); onChanged(); }
          });
        }} />
      )}
    </div>
  );
}

function AgreementTab({ data, canManage, canGenerate, onChanged }: { data: ApplicationDetailData; canManage: boolean; canGenerate: boolean; onChanged: () => void }) {
  const toast = useToast();
  const [templateId, setTemplateId] = useState("");
  const [assigning, startAssign] = useTransition();
  const [recovering, startRecovery] = useTransition();

  const activeTemplateKeys = new Set(data.signings.filter((signing) => signing.status !== "voided").map((signing) => signing.templateKey));
  const assignableTemplates = data.publishedTemplates.filter((template) => !activeTemplateKeys.has(template.template_key));

  return (
    <div className="space-y-3">
      <section className="min-w-0 rounded-md border border-desktop-border bg-card p-4">
        <h2 className="text-[14px] font-semibold text-desktop-text">Required Agreements for This Application</h2>
        {!data.requiredAgreementReadiness.initialized ? <>
          <p className="mt-2 text-[13px] text-muted-foreground">Agreement requirements have not been initialized.</p>
          {canManage && <Button type="button" size="sm" className="mt-3" disabled={recovering} onClick={() => startRecovery(async () => { const result = await initializeRequiredAgreements(data.id); if (!result.ok) toast.show("error", result.error); else { toast.show(result.auditWarning ? "info" : "success", result.auditWarning ?? "Required agreements initialized."); onChanged(); } })}>{recovering ? <Loader2 className="size-3.5 animate-spin" /> : null} Initialize Required Agreements</Button>}
        </> : <>
          <p className="mt-1 text-[12px] text-muted-foreground">Requirements established {new Date(data.requiredAgreementReadiness.initializedAt!).toLocaleString()}.</p>
          {data.requiredAgreementReadiness.requirements.length === 0 ? <p className="mt-3 text-[13px] text-muted-foreground">No agreements are required for this application.</p> : <div className="mt-3 space-y-2">{data.requiredAgreementReadiness.requirements.map((requirement) => <div key={requirement.templateKey} className="flex min-w-0 flex-wrap items-center justify-between gap-2 rounded-sm border border-desktop-border px-3 py-2"><div className="min-w-0"><p className="break-words text-[13px] font-medium">{requirement.signingTemplateName ?? requirement.initialTemplateName}</p><p className="break-all text-[11.5px] text-muted-foreground">{requirement.templateKey} · Initial v{requirement.initialTemplateVersion}{requirement.signingTemplateVersion ? ` · Assigned v${requirement.signingTemplateVersion}` : ""}</p></div><StatusBadge status={requirement.signingStatus ?? "missing"} /></div>)}</div>}
          {canManage && data.requiredAgreementReadiness.requirements.some((requirement) => !requirement.signingId) && <Button type="button" size="sm" className="mt-3" disabled={recovering} onClick={() => startRecovery(async () => { const result = await assignMissingRequiredAgreements(data.id); if (!result.ok) toast.show("error", result.error); else { toast.show(result.auditWarning ? "info" : "success", result.auditWarning ?? "Missing required agreements assigned."); onChanged(); } })}>{recovering ? <Loader2 className="size-3.5 animate-spin" /> : null} Assign Missing Required Agreements</Button>}
        </>}
      </section>
      {data.signings.length === 0 && <div className="rounded-md border border-desktop-border bg-card p-4 text-[13px] text-muted-foreground">No agreement has been assigned yet.</div>}
      {data.signings.map((s) => (
        <div key={s.id} className="rounded-md border border-desktop-border bg-card p-4">
          <div className="flex items-center gap-2">
            <h2 className="text-[14px] font-semibold text-desktop-text">{s.templateName} (v{s.templateVersion})</h2>
            <StatusBadge status={s.status} />
          </div>
          {(["completed", "voided"].includes(s.status) && s.signedAt) ? (
            <div className="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2">
              <Field label="Signed By" value={s.signerName} />
              <Field label="Signer Title" value={s.signerTitle} />
              <Field label="Signed Date/Time" value={s.signedAt ? new Date(s.signedAt).toLocaleString() : null} />
              <Field label="Evidence Status" value={s.evidenceHash ? "Recorded" : "--"} />
            </div>
          ) : (
            <p className="mt-2 text-[13px] text-muted-foreground">Waiting on the carrier to complete initials, consent, and signature.</p>
          )}
          {s.status === "voided" && s.signedAt && <p className="mt-2 text-[12px] text-muted-foreground">This executed agreement was later voided. Its historical artifact remains preserved and is excluded from new setup packages.</p>}
          {(["completed", "voided"].includes(s.status)) && (
            <ExecutedAgreementActions applicationId={data.id} signing={s} canGenerate={canGenerate} onChanged={onChanged} />
          )}
          <div className="mt-3 space-y-1.5">
            {s.clauses.map((c) => (
              <div key={c.id} className="flex items-center justify-between rounded-sm border border-desktop-border px-2.5 py-1.5 text-[12.5px]">
                <span className="text-desktop-text">{c.title}</span>
                {c.requiresInitials && <span className={c.typedInitials ? "text-desktop-success" : "text-muted-foreground"}>{c.typedInitials ?? "Not initialed"}</span>}
              </div>
            ))}
          </div>
        </div>
      ))}
      {canManage && (
        <div className="rounded-md border border-desktop-border bg-card p-4">
          <div className="flex flex-wrap items-center gap-2">
            <select value={templateId} onChange={(e) => setTemplateId(e.target.value)} className="h-8 rounded-sm border border-desktop-border bg-card px-2.5 text-[13px]">
              <option value="">Select a published template...</option>
              {assignableTemplates.map((t) => (
                <option key={t.id} value={t.id}>{t.name} (v{t.version_number})</option>
              ))}
            </select>
            <Button type="button" size="sm" disabled={!templateId || assigning} onClick={() => {
              startAssign(async () => {
                const result = await assignAgreementTemplate(data.id, templateId);
                if (!result.ok) toast.show("error", result.error);
                else { setTemplateId(""); toast.show(result.auditWarning ? "info" : "success", result.auditWarning ?? "Agreement assigned."); onChanged(); }
              });
            }}>
              {assigning ? "Assigning..." : "Assign Agreement"}
            </Button>
          </div>
          {assignableTemplates.length === 0 && <p className="mt-2 text-[12px] text-muted-foreground">All published agreement families already have an active assignment.</p>}
        </div>
      )}
    </div>
  );
}

function ExecutedAgreementActions({ applicationId, signing, canGenerate, onChanged }: { applicationId: string; signing: ApplicationDetailData["signings"][number]; canGenerate: boolean; onChanged: () => void }) {
  const toast = useToast();
  const [pending, start] = useTransition();
  const generated = Boolean(signing.generatedDocumentId && signing.documentGenerationStatus === "generated");
  return <div className="mt-3 flex flex-wrap items-center gap-2 border-t border-desktop-border pt-3">
    <span className="mr-1 text-[12px] text-muted-foreground">Executed PDF: {generated ? "Generated" : signing.documentGenerationStatus === "generating" ? "Generating" : signing.documentGenerationStatus === "failed" ? "Generation failed" : "Pending"}</span>
    {generated && <><Link href={`/carriers/onboarding/${applicationId}/agreements/${signing.id}/pdf`} target="_blank" className="inline-flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border px-3 text-[12px] font-medium hover:bg-muted"><Eye className="size-3.5" /> View Signed PDF</Link><Link href={`/carriers/onboarding/${applicationId}/agreements/${signing.id}/pdf?download=1`} className="inline-flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border px-3 text-[12px] font-medium hover:bg-muted"><Download className="size-3.5" /> Download</Link></>}
    {!generated && canGenerate && signing.documentGenerationStatus !== "generating" && <Button type="button" size="sm" variant="outline" disabled={pending} onClick={() => start(async () => { const result = await generateExecutedAgreement(applicationId, signing.id); if (!result.ok) toast.show("error", result.error); else { toast.show("success", result.state === "generated" ? "Executed PDF generated." : "Executed PDF generation is already in progress."); onChanged(); } })}>{pending ? <Loader2 className="size-3.5 animate-spin" /> : <FilePlus2 className="size-3.5" />} Generate PDF</Button>}
  </div>;
}

function ActivityTab({ data }: { data: ApplicationDetailData }) {
  if (data.activity.length === 0) return <div className="rounded-md border border-desktop-border bg-card p-4 text-[13px] text-muted-foreground">No activity yet.</div>;
  return (
    <div className="rounded-md border border-desktop-border bg-card p-4">
      <div className="space-y-2">
        {data.activity.map((a) => (
          <div key={a.id} className="flex items-center justify-between border-b border-desktop-border pb-2 text-[12.5px] last:border-0 last:pb-0">
            <span className="text-desktop-text">{formatAction(a.action)}{a.actorName ? ` -- ${a.actorName}` : ""}</span>
            <span className="text-muted-foreground">{new Date(a.createdAt).toLocaleString()}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
