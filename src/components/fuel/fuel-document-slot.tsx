import { DocumentSlot } from "@/components/shared/document-slot";
import type { DocumentRow } from "@/lib/documents/latest-document";
import { uploadFuelDocument, getFuelDocumentSignedUrl } from "@/app/(app)/fuel/actions";

// Thin, fuel-specific binding over the shared DocumentSlot (spec section
// 19: "Do not build a second receipt table" -- the upload UI itself is
// shared with Maintenance too, see components/shared/document-slot.tsx).
export function FuelDocumentSlot({ fuelLogId, documentType, label, doc }: { fuelLogId: string; documentType: string; label: string; doc: DocumentRow | null }) {
  return (
    <DocumentSlot
      label={label}
      doc={doc}
      uploadAction={uploadFuelDocument.bind(null, fuelLogId, documentType)}
      getUrl={doc ? getFuelDocumentSignedUrl.bind(null, doc.file_path, false) : async () => { throw new Error("No document on file."); }}
    />
  );
}
