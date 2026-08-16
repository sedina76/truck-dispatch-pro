import { redirect } from "next/navigation";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentDispatch } from "@/lib/driver-portal/dashboard-data";
import { getLatestDocument } from "@/lib/documents/latest-document";
import { computePodStatus } from "@/lib/documents/pod-status";
import { PodUpload } from "@/components/driver-portal/pod-upload";
import { TripDocumentUpload, type TripDocSlot } from "@/components/driver-portal/trip-document-upload";

const TRIP_DOC_TYPES: { type: string; label: string }[] = [
  { type: "bol", label: "Bill of Lading" },
  { type: "lumper_receipt", label: "Lumper Receipt" },
  { type: "scale_ticket", label: "Scale Ticket" },
  { type: "fuel_receipt", label: "Fuel Receipt" },
  { type: "other", label: "Other" },
];

// Trip Documents (spec sections 8-10). POD keeps using the existing
// driver POD workflow verbatim (PodUpload, /api/driver-portal/upload-pod,
// unchanged); everything else is new slots over the SAME documents table
// and load-documents bucket via uploadTripDocument (spec: "Do not create
// another document table").
export default async function DriverPortalDocumentsPage() {
  const identity = await getDriverPortalSession();
  if (!identity) redirect("/driver-portal/login");

  const supabase = createServiceRoleClient();
  const dispatch = await getCurrentDispatch(supabase, identity.driverId);

  if (!dispatch) {
    return (
      <div className="flex flex-1 flex-col gap-4">
        <h1 className="text-lg font-semibold tracking-tight">Trip Documents</h1>
        <div className="rounded-2xl border border-border bg-card p-4">
          <p className="text-sm text-muted-foreground">No active trip to upload documents for right now.</p>
        </div>
      </div>
    );
  }

  const [pod, ...tripDocs] = await Promise.all([
    getLatestDocument(supabase, "load", dispatch.load_id, "pod"),
    ...TRIP_DOC_TYPES.map((t) => getLatestDocument(supabase, "load", dispatch.load_id, t.type)),
  ]);
  const podStatus = computePodStatus(pod);

  const slots: TripDocSlot[] = TRIP_DOC_TYPES.map((t, i) => ({
    documentType: t.type,
    label: t.label,
    fileName: tripDocs[i]?.file_name ?? null,
    filePath: tripDocs[i]?.file_path ?? null,
    uploadedAt: tripDocs[i]?.created_at ?? null,
  }));

  return (
    <div className="flex flex-1 flex-col gap-4">
      <div>
        <h1 className="text-lg font-semibold tracking-tight">Trip Documents</h1>
        <p className="text-xs text-muted-foreground">{dispatch.load_number}</p>
      </div>

      <div className="rounded-2xl border border-border bg-card p-4">
        <PodUpload loadId={dispatch.load_id} status={podStatus} rejectionReason={pod?.rejection_reason} />
      </div>

      <div className="rounded-2xl border border-border bg-card p-4">
        {slots.map((slot) => (
          <TripDocumentUpload key={slot.documentType} loadId={dispatch.load_id} slot={slot} />
        ))}
      </div>
    </div>
  );
}
