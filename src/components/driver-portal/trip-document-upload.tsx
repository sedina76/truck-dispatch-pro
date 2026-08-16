"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Camera, FolderOpen, Loader2, FileCheck2 } from "lucide-react";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import { uploadTripDocument, getTripDocumentSignedUrl } from "@/app/driver-portal/actions";

export type TripDocSlot = {
  documentType: string;
  label: string;
  fileName: string | null;
  filePath: string | null;
  uploadedAt: string | null;
};

// Mobile-optimized document upload (spec section 10): large touch targets,
// separate "Take Photo" (camera capture) and "Choose Photo/PDF" (native
// file/photo picker) controls, private storage + signed URLs only via
// uploadTripDocument/getTripDocumentSignedUrl (reuses the load-documents
// bucket -- no new storage table).
export function TripDocumentUpload({ loadId, slot }: { loadId: string; slot: TripDocSlot }) {
  const router = useRouter();
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const cameraRef = useRef<HTMLInputElement>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  async function handleFile(file: File | undefined) {
    if (!file) return;
    setUploading(true);
    setError(null);
    const formData = new FormData();
    formData.append("file", file);
    try {
      await uploadTripDocument(loadId, slot.documentType, formData);
      router.refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Upload failed.");
    } finally {
      setUploading(false);
    }
  }

  return (
    <div className="border-t border-border py-3 first:border-t-0 first:pt-0">
      <div className="flex items-center justify-between">
        <p className="text-sm font-medium">{slot.label}</p>
        {slot.fileName && <FileCheck2 className="size-4 text-success" />}
      </div>

      {slot.fileName ? (
        <div className="mt-1.5 flex items-center justify-between gap-2">
          <div className="min-w-0">
            <p className="truncate text-xs text-muted-foreground">{slot.fileName}</p>
            {slot.uploadedAt && <p className="text-[10.5px] text-muted-foreground">{new Date(slot.uploadedAt).toLocaleString()}</p>}
          </div>
          {slot.filePath && <DocumentLinkButton label="View" getUrl={getTripDocumentSignedUrl.bind(null, slot.filePath, false)} />}
        </div>
      ) : (
        <p className="mt-1 text-xs text-muted-foreground">Not uploaded yet.</p>
      )}

      <div className="mt-2 flex gap-2">
        <button
          type="button"
          disabled={uploading}
          onClick={() => cameraRef.current?.click()}
          className="flex h-11 flex-1 items-center justify-center gap-1.5 rounded-xl border border-dashed border-border text-xs font-medium disabled:opacity-60"
        >
          {uploading ? <Loader2 className="size-4 animate-spin" /> : <Camera className="size-4" />}
          Take Photo
        </button>
        <button
          type="button"
          disabled={uploading}
          onClick={() => fileRef.current?.click()}
          className="flex h-11 flex-1 items-center justify-center gap-1.5 rounded-xl border border-dashed border-border text-xs font-medium disabled:opacity-60"
        >
          <FolderOpen className="size-4" />
          {slot.fileName ? "Replace File" : "Choose Photo/PDF"}
        </button>
      </div>
      <input ref={cameraRef} type="file" accept="image/*" capture="environment" className="hidden" onChange={(e) => handleFile(e.target.files?.[0])} />
      <input ref={fileRef} type="file" accept=".pdf,.jpg,.jpeg,.png" className="hidden" onChange={(e) => handleFile(e.target.files?.[0])} />

      {error && <p className="mt-1 text-xs text-danger">{error}</p>}
    </div>
  );
}
