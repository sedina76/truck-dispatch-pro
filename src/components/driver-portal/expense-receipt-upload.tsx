"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Camera, FolderOpen, Loader2 } from "lucide-react";
import { uploadDriverExpenseReceipt } from "@/app/driver-portal/actions";

export function ExpenseReceiptUpload({ expenseId, documentType }: { expenseId: string; documentType: string }) {
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
      await uploadDriverExpenseReceipt(expenseId, documentType, formData);
      router.refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Upload failed.");
    } finally {
      setUploading(false);
    }
  }

  return (
    <div>
      <div className="flex gap-2">
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
          Choose Photo/PDF
        </button>
      </div>
      <input ref={cameraRef} type="file" accept="image/*" capture="environment" className="hidden" onChange={(e) => handleFile(e.target.files?.[0])} />
      <input ref={fileRef} type="file" accept=".pdf,.jpg,.jpeg,.png" className="hidden" onChange={(e) => handleFile(e.target.files?.[0])} />
      {error && <p className="mt-1 text-xs text-danger">{error}</p>}
    </div>
  );
}
