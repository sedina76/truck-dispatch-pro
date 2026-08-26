"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Camera, FolderOpen, Loader2 } from "lucide-react";
import { uploadDriverExpenseReceipt } from "@/app/driver-portal/actions";
import { DocumentScanner } from "@/components/documents/document-scanner";

export function ExpenseReceiptUpload({ expenseId, documentType }: { expenseId: string; documentType: string }) {
  const router = useRouter();
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [scannerOpen, setScannerOpen] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  // Shared by the plain file/PDF picker and the scanner's onCapture
  // (Phase 2Q.1) -- both end up calling this exact same server action, so
  // a scanned receipt gets no different treatment than a chosen one.
  async function handleFile(file: File | undefined) {
    if (!file) return;
    setUploading(true);
    setError(null);
    const formData = new FormData();
    formData.append("file", file);
    try {
      await uploadDriverExpenseReceipt(expenseId, documentType, formData);
      router.refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Upload failed.");
      throw e; // re-thrown so the scanner (when it's the caller) keeps the scan and offers Retry
    } finally {
      setUploading(false);
    }
  }

  return (
    <div>
      <div className="flex gap-2">
        {/* Phase 2Q.1: "Take Photo" now opens the scanner (capture -> crop
            -> enhance -> preview) instead of uploading the raw photo
            straight off the camera -- same camera-capture technique
            underneath (see DocumentScanner's header comment), just with a
            review step before anything is sent. */}
        <button
          type="button"
          disabled={uploading}
          onClick={() => setScannerOpen(true)}
          className="flex h-11 flex-1 items-center justify-center gap-1.5 rounded-xl border border-dashed border-border text-xs font-medium disabled:opacity-60"
        >
          {uploading ? <Loader2 className="size-4 animate-spin" /> : <Camera className="size-4" />}
          Scan Receipt
        </button>
        <button
          type="button"
          disabled={uploading}
          onClick={() => fileRef.current?.click()}
          className="flex h-11 flex-1 items-center justify-center gap-1.5 rounded-xl border border-dashed border-border text-xs font-medium disabled:opacity-60"
        >
          <FolderOpen className="size-4" />
          Choose Photo/PDF
        </button>
      </div>
      <input ref={fileRef} type="file" accept=".pdf,.jpg,.jpeg,.png" className="hidden" onChange={(e) => handleFile(e.target.files?.[0])} />
      <DocumentScanner open={scannerOpen} onOpenChange={setScannerOpen} onCapture={handleFile} documentLabel="Receipt" />
      {error && <p className="mt-1 text-xs text-danger">{error}</p>}
    </div>
  );
}
