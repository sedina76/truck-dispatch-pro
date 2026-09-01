import { ConfirmDeleteForm } from "@/components/ui/confirm-delete-form";
import { StatusBadge } from "@/components/ui/status-badge";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import { CarrierDocumentUpload } from "@/components/carriers/carrier-document-upload";
import { computeDocumentStatus, DOCUMENT_TYPE_OPTIONS } from "@/lib/documents/library";
import {
  getCarrierDocumentSignedUrl,
  deleteCarrierDocument,
} from "@/app/(app)/carriers/carrier-document-actions";

const DOC_TYPE_LABEL = new Map(DOCUMENT_TYPE_OPTIONS.map((o) => [o.value, o.label]));

export type CarrierDocumentRow = {
  id: string;
  document_type: string;
  file_name: string;
  expiry_date: string | null;
  is_verified: boolean;
  created_at: string;
};

// Carrier Documents & Compliance surface. Lists this carrier's own
// documents (entity_type='carrier') and, for staff who may write them,
// offers the real upload form. Delete is offered only for the ordinary
// uploaded types -- protected/generated evidence (signed_agreement, w9) is
// never deletable here and never appears in the upload picker anyway.
export function CarrierDocumentsSection({
  carrierId,
  documents,
  canUpload,
  canVerify,
}: {
  carrierId: string;
  documents: CarrierDocumentRow[];
  canUpload: boolean;
  canVerify: boolean;
}) {
  return (
    <div className="space-y-4">
      <div className="rounded-md border border-desktop-border bg-card shadow-elevation-1">
        <div className="flex h-7 items-center rounded-t-md bg-desktop-header px-3 text-[11px] font-semibold uppercase tracking-wide text-desktop-header-text">
          Documents &amp; Compliance
        </div>
        <div className="space-y-4 p-4">
          {canUpload ? (
            <CarrierDocumentUpload carrierId={carrierId} canVerify={canVerify} />
          ) : (
            <p className="text-[12.5px] text-muted-foreground">
              You do not have permission to upload documents for this carrier.
            </p>
          )}

          <div className="overflow-x-auto rounded-sm border border-desktop-border">
            <table className="w-full min-w-max border-collapse text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border bg-desktop-muted text-left text-[11px] font-semibold text-muted-foreground">
                  <th className="h-7 px-2.5">Document Type</th>
                  <th className="h-7 px-2.5">File Name</th>
                  <th className="h-7 px-2.5">Uploaded</th>
                  <th className="h-7 px-2.5">Expiry</th>
                  <th className="h-7 px-2.5">Status</th>
                  <th className="h-7 px-2.5 text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                {documents.length === 0 ? (
                  <tr>
                    <td colSpan={6} className="px-2.5 py-4 text-center text-muted-foreground">
                      No documents on file for this carrier yet.
                    </td>
                  </tr>
                ) : (
                  documents.map((d) => {
                    const status = computeDocumentStatus(d.expiry_date, d.is_verified);
                    const protectedType = d.document_type === "signed_agreement" || d.document_type === "w9";
                    return (
                      <tr key={d.id} className="border-b border-desktop-border last:border-0">
                        <td className="h-8 px-2.5 align-middle">{DOC_TYPE_LABEL.get(d.document_type) ?? d.document_type}</td>
                        <td className="h-8 px-2.5 align-middle font-medium">{d.file_name}</td>
                        <td className="h-8 px-2.5 align-middle">{new Date(d.created_at).toLocaleDateString()}</td>
                        <td className="h-8 px-2.5 align-middle">
                          {d.expiry_date ? (
                            <span className={status === "expired" ? "text-desktop-danger" : undefined}>
                              {new Date(d.expiry_date + "T00:00:00").toLocaleDateString()}
                            </span>
                          ) : (
                            <span className="text-muted-foreground">--</span>
                          )}
                        </td>
                        <td className="h-8 px-2.5 align-middle">
                          <StatusBadge status={status} />
                        </td>
                        <td className="h-8 px-2.5 align-middle">
                          <div className="flex items-center justify-end gap-2">
                            <DocumentLinkButton
                              label="View"
                              getUrl={getCarrierDocumentSignedUrl.bind(null, d.id, false)}
                            />
                            <DocumentLinkButton
                              label="Download"
                              getUrl={getCarrierDocumentSignedUrl.bind(null, d.id, true)}
                            />
                            {canUpload && !protectedType && (
                              <ConfirmDeleteForm action={deleteCarrierDocument.bind(null, d.id, carrierId)} />
                            )}
                          </div>
                        </td>
                      </tr>
                    );
                  })
                )}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
  );
}
