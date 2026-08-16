import { Button } from "@/components/ui/button";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import type { DocumentRow } from "@/lib/documents/latest-document";
import { uploadLoadDocument, getPodSignedUrl } from "@/app/(app)/loads/pod-actions";

// Upload-and-view only -- no verify/reject workflow. That cycle is specific
// to POD (see the Proof of Delivery section on the load page); rate
// confirmations, BOLs, and accessorial receipts are simpler "on file or
// not" documents by design (see 0024_billing_packets.sql). Plain Server
// Component -- same visible-file-input-plus-submit-button pattern as the
// POD upload form, no client-side auto-submit trick needed.
export function SimpleDocumentSlot({
  loadId,
  documentType,
  label,
  doc,
}: {
  loadId: string;
  documentType: string;
  label: string;
  doc: DocumentRow | null;
}) {
  return (
    <div className="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--color-border)] py-2 last:border-0">
      <span className="text-sm">
        {doc ? (
          <span className="text-success">&#10003;</span>
        ) : (
          <span className="text-[var(--color-text-muted)]">&#9675;</span>
        )}{" "}
        {label}
        {!doc && <span className="ml-1 text-xs text-[var(--color-text-muted)]">-- not on file</span>}
      </span>
      <div className="flex items-center gap-2">
        {doc && <DocumentLinkButton label="View" getUrl={getPodSignedUrl.bind(null, doc.file_path, false)} />}
        <form action={uploadLoadDocument.bind(null, loadId, documentType)} className="flex items-center gap-1.5">
          <input
            type="file"
            name="file"
            accept=".pdf,.jpg,.jpeg,.png"
            required
            className="w-32 text-[11px] text-[var(--color-text-muted)] file:mr-1 file:rounded file:border-0 file:bg-muted file:px-1.5 file:py-0.5 file:text-[10px]"
          />
          <Button type="submit" size="sm" variant="outline">
            {doc ? "Replace" : "Upload"}
          </Button>
        </form>
      </div>
    </div>
  );
}
