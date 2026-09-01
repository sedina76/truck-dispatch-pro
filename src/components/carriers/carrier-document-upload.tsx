"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { uploadCarrierDocument } from "@/app/(app)/carriers/carrier-document-actions";
import { MAX_UPLOAD_BYTES, ALLOWED_UPLOAD_MIME_TYPES } from "@/lib/documents/upload-limits";
import { CARRIER_UPLOAD_DOCUMENT_TYPES, DOCUMENT_TYPE_OPTIONS } from "@/lib/documents/library";

const DOC_TYPE_LABEL = new Map(DOCUMENT_TYPE_OPTIONS.map((o) => [o.value, o.label]));

const FIELD_CLASS =
  "h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20 disabled:opacity-50";

// Real carrier document upload -- sends actual bytes to uploadCarrierDocument()
// (server), which uploads to private storage and then writes the documents
// row atomically. Mirrors <UploadDocumentForm> (loads) in structure: client
// pre-checks size/type only to avoid Next's Server Action body-size boundary;
// the server checks are authoritative.
export function CarrierDocumentUpload({
  carrierId,
  canVerify,
}: {
  carrierId: string;
  canVerify: boolean;
}) {
  const router = useRouter();
  const fileRef = useRef<HTMLInputElement>(null);
  const [documentType, setDocumentType] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);

    const form = e.currentTarget;
    const file = fileRef.current?.files?.[0];
    if (!documentType) {
      setError("Choose a document type.");
      return;
    }
    if (!file) {
      setError("Choose a file.");
      return;
    }
    if (file.size > MAX_UPLOAD_BYTES) {
      setError("File is too large (15 MB max).");
      return;
    }
    if (!(ALLOWED_UPLOAD_MIME_TYPES as readonly string[]).includes(file.type)) {
      setError("Unsupported file type. Use PDF, JPG, or PNG.");
      return;
    }

    const fd = new FormData(form);
    fd.set("file", file);

    setLoading(true);
    let result: Awaited<ReturnType<typeof uploadCarrierDocument>>;
    try {
      result = await uploadCarrierDocument(carrierId, documentType, fd);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not upload this file.");
      setLoading(false);
      return;
    }
    setLoading(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    form.reset();
    setDocumentType("");
    router.refresh();
  }

  return (
    <form onSubmit={handleSubmit} className="grid grid-cols-1 gap-3 sm:grid-cols-2">
      <div className="min-w-0 space-y-1">
        <label htmlFor="carrier_doc_type" className="text-[12px] font-medium text-desktop-text">
          Document type<span className="text-danger"> *</span>
        </label>
        <select
          id="carrier_doc_type"
          className={FIELD_CLASS}
          value={documentType}
          onChange={(e) => setDocumentType(e.target.value)}
          disabled={loading}
        >
          <option value="" disabled>
            Select...
          </option>
          {CARRIER_UPLOAD_DOCUMENT_TYPES.map((t) => (
            <option key={t} value={t}>
              {DOC_TYPE_LABEL.get(t) ?? t}
            </option>
          ))}
        </select>
      </div>

      <div className="min-w-0 space-y-1">
        <label htmlFor="carrier_doc_file" className="text-[12px] font-medium text-desktop-text">
          File<span className="text-danger"> *</span>
        </label>
        <input
          ref={fileRef}
          id="carrier_doc_file"
          type="file"
          name="file"
          accept=".pdf,.jpg,.jpeg,.png"
          required
          disabled={loading}
          className="w-full text-[12px] text-muted-foreground file:mr-2 file:rounded-sm file:border-0 file:bg-primary file:px-3 file:py-1.5 file:text-xs file:font-medium file:text-primary-foreground disabled:opacity-60"
        />
      </div>

      <div className="min-w-0 space-y-1">
        <label htmlFor="carrier_doc_expiry" className="text-[12px] font-medium text-desktop-text">
          Expiry date
        </label>
        <input id="carrier_doc_expiry" type="date" name="expiry_date" disabled={loading} className={FIELD_CLASS} />
        <p className="text-[11px] text-muted-foreground">Optional — for credentials that expire.</p>
      </div>

      <div className="flex items-end gap-3">
        {canVerify && (
          <label className="flex items-center gap-2 pb-1 text-[13px] font-medium text-desktop-text">
            <input type="checkbox" name="is_verified" disabled={loading} className="size-4 rounded border-desktop-border" />
            Mark verified
          </label>
        )}
        <Button type="submit" size="sm" disabled={loading} className="ml-auto">
          {loading ? <Loader2 className="size-3.5 animate-spin" /> : null}
          Upload Document
        </Button>
      </div>

      {error && <p className="sm:col-span-2 text-xs text-danger">{error}</p>}
    </form>
  );
}
