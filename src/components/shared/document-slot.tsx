import { Button } from "@/components/ui/button";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import type { DocumentRow } from "@/lib/documents/latest-document";

// Same "upload-and-view, one slot per document type" shape used across
// every module with a polymorphic-documents-table upload flow (loads'
// SimpleDocumentSlot, Maintenance, and now Fuel Logs, 0051) -- one shared
// component taking pre-bound server actions rather than a fourth near-
// identical copy (spec, both Maintenance and Fuel: "Do NOT create another
// document table" -- extending to "do not re-implement the upload UI
// either"). `uploadAction`/`getUrl` are expected to already be bound to
// their entity id and document type (e.g.
// `uploadFuelDocument.bind(null, fuelLogId, documentType)`), so this
// component itself never needs to know which entity_type it's for.
export function DocumentSlot({
  label,
  doc,
  uploadAction,
  getUrl,
}: {
  label: string;
  doc: DocumentRow | null;
  uploadAction: (formData: FormData) => Promise<void>;
  getUrl: () => Promise<string>;
}) {
  return (
    <div className="flex flex-wrap items-center justify-between gap-2 border-b border-desktop-border py-2 last:border-0">
      <span className="text-[12.5px]">
        {doc ? <span className="text-desktop-success">&#10003;</span> : <span className="text-muted-foreground">&#9675;</span>} {label}
        {!doc && <span className="ml-1 text-[11px] text-muted-foreground">-- not on file</span>}
      </span>
      <div className="flex items-center gap-2">
        {doc && <DocumentLinkButton label="View" getUrl={getUrl} />}
        <form action={uploadAction} className="flex items-center gap-1.5">
          <input
            type="file"
            name="file"
            accept=".pdf,.jpg,.jpeg,.png"
            required
            className="w-32 text-[11px] text-muted-foreground file:mr-1 file:rounded file:border-0 file:bg-muted file:px-1.5 file:py-0.5 file:text-[10px]"
          />
          <Button type="submit" size="sm" variant="outline">{doc ? "Replace" : "Upload"}</Button>
        </form>
      </div>
    </div>
  );
}
