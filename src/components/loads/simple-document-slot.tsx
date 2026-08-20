import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import { UploadDocumentForm } from "@/components/loads/upload-document-form";
import type { DocumentRow } from "@/lib/documents/latest-document";
import { getPodSignedUrl, getFinancialDocumentSignedUrl } from "@/app/(app)/loads/pod-actions";

// Upload-and-view only -- no verify/reject workflow. That cycle is specific
// to POD (see the Proof of Delivery section on the load page); rate
// confirmations, BOLs, and accessorial receipts are simpler "on file or
// not" documents by design (see 0024_billing_packets.sql). Still a plain
// Server Component -- UploadDocumentForm is the client "island" that
// actually submits (typed-result/inline-error, see its own header
// comment), same pattern DocumentLinkButton already uses right below.
export function SimpleDocumentSlot({
  loadId,
  documentType,
  label,
  doc,
  onUploaded,
}: {
  loadId: string;
  documentType: string;
  label: string;
  doc: DocumentRow | null;
  // Passed straight through to UploadDocumentForm -- see its own header
  // comment (Phase 2I.1). undefined for every caller except the Dispatch
  // Drawer's DocumentsPanel, which is the only one with a second,
  // independently-fetched data source that router.refresh() can't reach.
  onUploaded?: () => void | Promise<void>;
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
        {/* Phase 2G.8: rate_confirmation is the one financial document type
            this generic slot renders -- its signed URL is generated
            through the FINANCIAL_ROLES-gated variant so the authorization
            check happens before a URL is ever created, not just before
            this button is rendered. */}
        {doc && (
          <DocumentLinkButton
            label="View"
            getUrl={(documentType === "rate_confirmation" ? getFinancialDocumentSignedUrl : getPodSignedUrl).bind(null, doc.file_path, false)}
          />
        )}
        <UploadDocumentForm loadId={loadId} documentType={documentType} label={doc ? "Replace" : "Upload"} compact buttonVariant="outline" onUploaded={onUploaded} />
      </div>
    </div>
  );
}
