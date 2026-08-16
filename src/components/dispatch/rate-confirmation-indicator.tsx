import { CheckCircle2, Circle } from "lucide-react";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import { getPodSignedUrl } from "@/app/(app)/loads/pod-actions";
import type { DocumentRow } from "@/lib/documents/latest-document";

// Read-only indicator, staff-only page (this whole (app) route group
// requires a real Supabase Auth staff session -- no driver/carrier ever
// reaches it). Reuses the exact same signed-URL path Load Detail's
// Billing Documents section uses (getPodSignedUrl, RLS-scoped, private
// bucket, 300s expiry) -- never re-uploads, never duplicates the document
// system. Upload/replace happens on the Load page, not here, since Rate
// Confirmation belongs to the LOAD (customer/broker paperwork), not the
// dispatch (carrier assignment).
export function RateConfirmationIndicator({ doc, loadId }: { doc: DocumentRow | null; loadId: string }) {
  return (
    <div className="flex items-center justify-between text-[13px]">
      {doc ? (
        <span className="flex items-center gap-1.5 text-desktop-success">
          <CheckCircle2 className="size-4" /> Uploaded -- {doc.file_name}
        </span>
      ) : (
        <span className="flex items-center gap-1.5 text-desktop-text-muted">
          <Circle className="size-4" /> Not Uploaded
        </span>
      )}
      <div className="flex items-center gap-2">
        {doc && <DocumentLinkButton label="View" getUrl={getPodSignedUrl.bind(null, doc.file_path, false)} />}
        <a href={`/loads/${loadId}`} className="text-[12px] font-medium text-primary hover:underline">
          {doc ? "Replace on Load" : "Upload on Load"} &rarr;
        </a>
      </div>
    </div>
  );
}
