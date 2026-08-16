import { DocumentSlot } from "@/components/shared/document-slot";
import type { DocumentRow } from "@/lib/documents/latest-document";
import { uploadMaintenanceDocument, getMaintenanceDocumentSignedUrl } from "@/app/(app)/maintenance/actions";

// Thin, maintenance-specific binding over the shared DocumentSlot (spec
// DOCUMENT MANAGEMENT: "Do NOT create another document table" -- the
// upload UI itself is now shared with Fuel Logs too, see
// components/shared/document-slot.tsx).
export function MaintenanceDocumentSlot({ maintenanceId, documentType, label, doc }: { maintenanceId: string; documentType: string; label: string; doc: DocumentRow | null }) {
  return (
    <DocumentSlot
      label={label}
      doc={doc}
      uploadAction={uploadMaintenanceDocument.bind(null, maintenanceId, documentType)}
      getUrl={doc ? getMaintenanceDocumentSignedUrl.bind(null, doc.file_path, false) : async () => { throw new Error("No document on file."); }}
    />
  );
}
